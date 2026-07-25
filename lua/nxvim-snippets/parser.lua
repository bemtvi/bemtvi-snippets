-- The LSP / VSCode snippet-body grammar parser.
--
-- Parses the snippet syntax into an AST that `layout` turns into concrete text plus
-- per-tabstop byte spans at EXPAND time — variables (`$TM_FILENAME`, `$CURRENT_YEAR`,
-- …) resolve against runtime context, so they can't be flattened at parse time.
--
-- Supported grammar:
--   $N / ${N}            a tabstop (N a non-negative integer; $0 is the final stop)
--   ${N:default}         a placeholder — `default` is a nested node list
--   ${N|a,b,c|}          a choice — the first alternative is the default text
--   a repeated N         a mirror (every occurrence renders index N's default)
--   $VAR / ${VAR}        a variable (resolved at expand; unknown ⇒ empty / default)
--   ${VAR:default}       a variable with a fallback node list
--   ${N/re/fmt/opts}     a transform (and the variable form `${VAR/…/…/}`) —
--                        parsed here, applied by transform.lua; a TABSTOP transform
--                        is re-applied live by the session as its source changes
--   \$  \}  \\           escapes (and \, \| inside a choice list)
--
-- A malformed body raises rather than being silently dropped (the project's
-- no-silent-stubs rule), so a snippet never mis-expands quietly.

local M = {}

-- Is `b` an ASCII digit byte?
local function is_digit(b)
  return b ~= nil and b >= 48 and b <= 57
end

-- Is `b` a variable-name byte (`[A-Za-z_]`, and digits after the first)?
local function is_name_start(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end
local function is_name_char(b)
  return is_name_start(b) or is_digit(b)
end

-- A cursor over the body string: `s` and a 1-based position `i`.
local function reader(s)
  return { s = s, i = 1, n = #s }
end
local function peek(r)
  return r.i <= r.n and r.s:byte(r.i) or nil
end
local function advance(r)
  local b = peek(r)
  r.i = r.i + 1
  return b
end

-- Read a run of digits as an integer (at least one digit guaranteed by the caller).
local function read_int(r)
  local start = r.i
  while is_digit(peek(r)) do
    r.i = r.i + 1
  end
  return tonumber(r.s:sub(start, r.i - 1))
end

-- Read a variable name (`[A-Za-z_][A-Za-z0-9_]*`).
local function read_name(r)
  local start = r.i
  while is_name_char(peek(r)) do
    r.i = r.i + 1
  end
  return r.s:sub(start, r.i - 1)
end

local transform = require("nxvim-snippets.transform")

local parse_nodes -- forward declaration (recursive with the braced parsers)

-- Raise the one RECOVERABLE parse failure: a `${...}` that is closed but isn't a legal
-- construct (`${ami-name}` — a hyphen is not a variable char). VSCode renders such a
-- group literally, so `parse_dollar` backtracks when it sees this. It is raised as a
-- TABLE so that test is an identity check on the sentinel rather than a substring match
-- on a message (which would silently start swallowing real errors if one were ever
-- worded with the word "malformed"). Every other failure is a plain string error and
-- stays loud.
local MALFORMED = {}
local MALFORMED_MT = {
  -- Only `parse_dollar` ever sees one of these, but if a future caller lets one escape
  -- it must still read as its message, not as `table: 0x…`.
  __tostring = function(err)
    return err.message
  end,
}
local function malformed(msg)
  error(setmetatable({ [MALFORMED] = true, message = msg }, MALFORMED_MT), 0)
end
local function is_malformed(err)
  return type(err) == "table" and err[MALFORMED] == true
end

-- ----- transform parsing (${N/regex/format/options}) ------------------------

-- Read the `regex` part (positioned just after the opening `/`), up to the unescaped
-- `/` that ends it (consumed). `\/` becomes a literal slash; every other `\x` is kept
-- verbatim for the regex engine.
local function read_regex(r)
  local buf = {}
  while true do
    local b = peek(r)
    if b == nil then
      error("nxvim-snippets: unterminated transform regex")
    elseif b == 92 then
      advance(r)
      local e = advance(r)
      if e == 47 then
        buf[#buf + 1] = "/"
      else
        buf[#buf + 1] = "\\" .. (e and string.char(e) or "")
      end
    elseif b == 47 then
      advance(r)
      break
    else
      buf[#buf + 1] = string.char(advance(r))
    end
  end
  return table.concat(buf)
end

-- Read format text until (and consuming) the first unescaped byte in `stops`. Honors
-- \n \t \r and \<char> escapes.
local function read_format_text(r, stops)
  local set = {}
  for _, s in ipairs(stops) do
    set[s] = true
  end
  local buf = {}
  while true do
    local b = peek(r)
    if b == nil then
      error("nxvim-snippets: unterminated transform format")
    elseif set[b] then
      advance(r)
      break
    elseif b == 92 then
      advance(r)
      local e = advance(r)
      if e == 110 then
        buf[#buf + 1] = "\n"
      elseif e == 116 then
        buf[#buf + 1] = "\t"
      elseif e == 114 then
        buf[#buf + 1] = "\r"
      else
        buf[#buf + 1] = e and string.char(e) or "\\"
      end
    else
      buf[#buf + 1] = string.char(advance(r))
    end
  end
  return table.concat(buf)
end

-- Parse a `${N...}` format group (positioned just past the `{`). Returns a `group` node:
--   ${N}          -> plain reference
--   ${N:/upcase}  -> a case op
--   ${N:+if}      -> if group matched
--   ${N:-else} / ${N:else} -> if group empty
--   ${N:?if:else} -> conditional
local function parse_format_group(r)
  local index = read_int(r)
  if index == nil then
    -- `${:/upcase}` names no capture group: rendering it would quietly produce
    -- nothing, so refuse it instead of mis-expanding.
    error("nxvim-snippets: transform format group `${...}` needs a capture number")
  end
  local b = advance(r) -- } or :
  if b == 125 then
    return { kind = "group", index = index }
  elseif b == 58 then
    local c = peek(r)
    if c == 47 then -- :/op
      advance(r)
      local op = read_name(r)
      if advance(r) ~= 125 then
        error("nxvim-snippets: malformed transform `${N:/op}`")
      end
      return { kind = "group", index = index, op = op }
    elseif c == 43 then -- :+if
      advance(r)
      return { kind = "group", index = index, if_text = read_format_text(r, { 125 }) }
    elseif c == 45 then -- :-else
      advance(r)
      return { kind = "group", index = index, else_text = read_format_text(r, { 125 }) }
    elseif c == 63 then -- :?if:else
      advance(r)
      local iff = read_format_text(r, { 58 })
      local els = read_format_text(r, { 125 })
      return { kind = "group", index = index, if_text = iff, else_text = els }
    else -- :else
      return { kind = "group", index = index, else_text = read_format_text(r, { 125 }) }
    end
  end
  error("nxvim-snippets: malformed transform format group")
end

-- Parse the `format` part (positioned just after the second `/`), up to the unescaped
-- `/` that ends it (consumed). Returns a list of text / group nodes.
local function parse_format(r)
  local nodes, buf = {}, {}
  local function flush()
    if #buf > 0 then
      nodes[#nodes + 1] = { kind = "text", text = table.concat(buf) }
      buf = {}
    end
  end
  while true do
    local b = peek(r)
    if b == nil then
      error("nxvim-snippets: unterminated transform format")
    elseif b == 47 then
      advance(r)
      break
    elseif b == 92 then
      advance(r)
      local e = advance(r)
      if e == 110 then
        buf[#buf + 1] = "\n"
      elseif e == 116 then
        buf[#buf + 1] = "\t"
      elseif e == 114 then
        buf[#buf + 1] = "\r"
      else
        buf[#buf + 1] = e and string.char(e) or "\\"
      end
    elseif b == 36 then -- $
      advance(r)
      local nb = peek(r)
      if is_digit(nb) then
        flush()
        nodes[#nodes + 1] = { kind = "group", index = read_int(r) }
      elseif nb == 123 then
        advance(r)
        flush()
        nodes[#nodes + 1] = parse_format_group(r)
      else
        buf[#buf + 1] = "$"
      end
    else
      buf[#buf + 1] = string.char(advance(r))
    end
  end
  flush()
  return nodes
end

-- Read the `options` part (positioned just after the third `/`) up to (and consuming)
-- the closing `}`. A short run of flag letters (`g`, `i`, `m`, …).
local function read_options(r)
  local buf = {}
  while true do
    local b = peek(r)
    if b == nil then
      error("nxvim-snippets: unterminated transform (missing `}`)")
    elseif b == 125 then
      advance(r)
      break
    else
      buf[#buf + 1] = string.char(advance(r))
    end
  end
  return table.concat(buf)
end

-- Parse a whole transform, positioned just after the first `/`. Returns
-- `{ regex, format, options }`.
local function parse_transform(r)
  local regex = read_regex(r)
  local format = parse_format(r)
  local options = read_options(r)
  return { regex = regex, format = format, options = options }
end

-- Parse the alternatives of a `${N|a,b,c|}` choice, positioned just past the `|`.
-- Returns the list of alternative strings; leaves the cursor just past the closing `|`.
local function parse_choices(r)
  local choices, cur = {}, {}
  while true do
    local b = peek(r)
    if b == nil then
      error("nxvim-snippets: unterminated choice `${N|...`")
    elseif b == 92 then -- backslash: \, \| \\ inside a choice
      advance(r)
      local e = advance(r)
      cur[#cur + 1] = e and string.char(e) or "\\"
    elseif b == 44 then -- comma: next alternative
      advance(r)
      choices[#choices + 1] = table.concat(cur)
      cur = {}
    elseif b == 124 then -- closing pipe
      advance(r)
      choices[#choices + 1] = table.concat(cur)
      break
    else
      cur[#cur + 1] = string.char(advance(r))
    end
  end
  return choices
end

-- Parse a `${...}` construct, positioned just past the `{`. Returns one node.
local function parse_braced(r)
  local b = peek(r)
  if is_digit(b) then
    local index = read_int(r)
    local nb = advance(r) -- consume the following byte: } : | or /
    if nb == 125 then -- }
      return { kind = "tabstop", index = index, children = {} }
    elseif nb == 58 then -- :  placeholder
      local children = parse_nodes(r, true)
      return { kind = "tabstop", index = index, children = children }
    elseif nb == 124 then -- |  choice
      local choices = parse_choices(r)
      if advance(r) ~= 125 then -- expect the closing }
        error("nxvim-snippets: choice `${N|...|` must be followed by `}`")
      end
      return { kind = "tabstop", index = index, children = {}, choices = choices }
    elseif nb == 47 then -- /  transform
      return { kind = "tabstop", index = index, children = {}, transform = parse_transform(r) }
    else
      malformed("nxvim-snippets: malformed `${" .. index .. "...}` (unexpected byte)")
    end
  elseif is_name_start(b) then
    local name = read_name(r)
    local nb = advance(r)
    if nb == 125 then -- }
      return { kind = "var", name = name, children = {} }
    elseif nb == 58 then -- :  variable with default
      local children = parse_nodes(r, true)
      return { kind = "var", name = name, children = children }
    elseif nb == 47 then -- /  variable transform
      return { kind = "var", name = name, children = {}, transform = parse_transform(r) }
    else
      malformed("nxvim-snippets: malformed `${" .. name .. "...}` (unexpected byte)")
    end
  end
  malformed("nxvim-snippets: malformed `${...}` (expected a tabstop number or variable name)")
end

-- Parse a `$...` construct positioned just past the `$`. Returns one node, or a text
-- node for a bare `$` that isn't a tabstop/variable.
--
-- A `${...}` that isn't a valid construct (e.g. `${ami-name}` — a hyphen isn't a legal
-- variable char; common in terraform snippets that want a literal `${...}`) is treated
-- as LITERAL text, exactly as VSCode does: backtrack and emit the `$` as text. Only a
-- genuine TRANSFORM inside the braces is a refused construct — that error is re-raised.
local function parse_dollar(r)
  local b = peek(r)
  if is_digit(b) then
    return { kind = "tabstop", index = read_int(r), children = {} }
  elseif b == 123 then -- {
    local save = r.i
    advance(r) -- consume {
    local ok, node = pcall(parse_braced, r)
    if ok then
      return node
    end
    -- Only a CLOSED-but-malformed group (a bad name char, e.g. `${ami-name}`) falls back
    -- to literal, matching VSCode. An unterminated `${...` or a refused transform stays
    -- loud.
    if not is_malformed(node) then
      error(node, 0)
    end
    r.i = save -- the `$` is literal; reparse from the `{`
    return { kind = "text", text = "$" }
  elseif is_name_start(b) then
    return { kind = "var", name = read_name(r), children = {} }
  end
  return { kind = "text", text = "$" } -- a literal dollar
end

-- Parse a node list. When `in_brace` is true, stop at the matching `}` (a placeholder
-- / variable default) and consume it; at top level, run to the end of the body.
function parse_nodes(r, in_brace)
  local nodes, buf = {}, {}
  local function flush_text()
    if #buf > 0 then
      nodes[#nodes + 1] = { kind = "text", text = table.concat(buf) }
      buf = {}
    end
  end
  while true do
    local b = peek(r)
    if b == nil then
      if in_brace then
        error("nxvim-snippets: unterminated `${...}`")
      end
      break
    elseif b == 125 and in_brace then -- } closes this brace group
      advance(r)
      break
    elseif b == 92 then -- backslash escape: \$ \} \\ (others kept literal)
      advance(r)
      local e = advance(r)
      buf[#buf + 1] = e and string.char(e) or "\\"
    elseif b == 36 then -- $
      advance(r)
      local node = parse_dollar(r)
      if node.kind == "text" then
        buf[#buf + 1] = node.text
      else
        flush_text()
        nodes[#nodes + 1] = node
      end
    else
      buf[#buf + 1] = string.char(advance(r))
    end
  end
  flush_text()
  return nodes
end

-- parse(body) -> AST (a node list). Raises on malformed / unsupported input.
function M.parse(body)
  if type(body) ~= "string" then
    error("nxvim-snippets.parser: body must be a string, got " .. type(body))
  end
  return parse_nodes(reader(body), false)
end

-- Walk the AST collecting each tabstop index's DEFAULT node list — the first
-- occurrence that carries a body (choice's first alternative, or placeholder
-- children). Every occurrence (mirror) renders this shared default.
local function collect_defaults(nodes, defaults)
  for _, n in ipairs(nodes) do
    if n.kind == "tabstop" then
      if defaults[n.index] == nil then
        if n.choices and #n.choices > 0 then
          defaults[n.index] = { { kind = "text", text = n.choices[1] } }
        elseif n.children and #n.children > 0 then
          defaults[n.index] = n.children
        end
      end
      collect_defaults(n.children or {}, defaults)
    elseif n.kind == "var" then
      collect_defaults(n.children or {}, defaults)
    end
  end
end

-- Render a node list to a plain STRING (variables resolved, nested tabstop defaults
-- inlined) — the source value a transform is applied to.
local function text_of(nodes, resolve, seen)
  seen = seen or {}
  local parts = {}
  for _, n in ipairs(nodes or {}) do
    if n.kind == "text" then
      parts[#parts + 1] = n.text
    elseif n.kind == "var" then
      local v = resolve and resolve(n.name)
      if n.transform then
        v = transform.apply(v or "", n.transform)
      elseif v == nil or v == "" then
        v = text_of(n.children, resolve, seen)
      end
      parts[#parts + 1] = v or ""
    elseif n.kind == "tabstop" and not seen[n.index] then
      seen[n.index] = true
      parts[#parts + 1] = text_of(n.children, resolve, seen)
      seen[n.index] = nil
    end
  end
  return table.concat(parts)
end

-- layout(ast, resolve) -> text, stops
--   `resolve(name)` returns a variable's value string, or nil to fall back to its
--   default node list. `text` is the concrete expansion; `stops` is
--   `{ [index] = { { start_byte, end_byte, transform? }, ... } }` — every occurrence's
--   byte span in `text` (0-based, end-exclusive) plus its transform spec when it's a
--   `${N/re/fmt/}` occurrence (so the session recomputes it live). Byte offsets,
--   matching nxvim's text model.
function M.layout(ast, resolve)
  local defaults = {}
  collect_defaults(ast, defaults)
  local parts, len, stops = {}, 0, {}
  local function emit(s)
    parts[#parts + 1] = s
    len = len + #s
  end
  -- `expanding` guards a self-referential tabstop default (`${1:${1:…}}`): while an
  -- index's default is being laid out, a nested reference to the same index renders
  -- empty instead of recursing forever.
  local expanding = {}
  local function walk(nodes)
    for _, n in ipairs(nodes) do
      if n.kind == "text" then
        emit(n.text)
      elseif n.kind == "tabstop" then
        local s = len
        if n.transform then
          -- A transformed occurrence renders the transform of the index's value (its
          -- default, initially); the session re-applies it as the source tabstop changes.
          emit(transform.apply(text_of(defaults[n.index] or {}, resolve), n.transform))
        elseif not expanding[n.index] then
          expanding[n.index] = true
          walk(defaults[n.index] or {})
          expanding[n.index] = nil
        end
        stops[n.index] = stops[n.index] or {}
        -- A choice stop (`${N|a,b,c|}`) carries its alternatives so the session can
        -- offer them as a dropdown instead of a plain type-over default.
        if n.choices and #n.choices > 0 and not stops[n.index].choices then
          stops[n.index].choices = n.choices
        end
        local occ = { s, len }
        occ.transform = n.transform
        stops[n.index][#stops[n.index] + 1] = occ
      elseif n.kind == "var" then
        local v = resolve and resolve(n.name)
        if n.transform then
          emit(transform.apply(v or "", n.transform))
        elseif v ~= nil and v ~= "" then
          emit(v)
        else
          walk(n.children or {})
        end
      end
    end
  end
  walk(ast)
  return table.concat(parts), stops
end

return M
