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
--   \$  \}  \\           escapes (and \, \| inside a choice list)
--
-- Transforms (`${N/regex/format/opts}`, `${VAR/…/…/}`) are rejected LOUD rather than
-- silently dropped — the project's no-silent-stubs rule. They're a documented gap
-- (they need a live regex mirror; see the README), not a stub that quietly misbehaves.

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

local parse_nodes -- forward declaration (recursive with the braced parsers)

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
    elseif nb == 47 then -- /  transform (deferred, fail loud)
      error(
        "nxvim-snippets: tabstop transforms `${" .. index .. "/.../.../}` are not supported yet"
      )
    else
      error("nxvim-snippets: malformed `${" .. index .. "...}` (unexpected byte)")
    end
  elseif is_name_start(b) then
    local name = read_name(r)
    local nb = advance(r)
    if nb == 125 then -- }
      return { kind = "var", name = name, children = {} }
    elseif nb == 58 then -- :  variable with default
      local children = parse_nodes(r, true)
      return { kind = "var", name = name, children = children }
    elseif nb == 47 then -- /  variable transform (deferred, fail loud)
      error("nxvim-snippets: variable transforms `${" .. name .. "/.../}` are not supported yet")
    else
      error("nxvim-snippets: malformed `${" .. name .. "...}` (unexpected byte)")
    end
  end
  error("nxvim-snippets: malformed `${...}` (expected a tabstop number or variable name)")
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
    if not tostring(node):match("malformed") then
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

-- layout(ast, resolve) -> text, stops
--   `resolve(name)` returns a variable's value string, or nil to fall back to its
--   default node list. `text` is the concrete expansion; `stops` is
--   `{ [index] = { {start_byte, end_byte}, ... } }` — every occurrence's byte span in
--   `text` (0-based, end-exclusive), so the session can anchor a growing extmark over
--   each. Byte offsets, matching nxvim's text model.
function M.layout(ast, resolve)
  local defaults = {}
  collect_defaults(ast, defaults)
  local parts, len, stops = {}, 0, {}
  local function emit(s)
    parts[#parts + 1] = s
    len = len + #s
  end
  local function walk(nodes)
    for _, n in ipairs(nodes) do
      if n.kind == "text" then
        emit(n.text)
      elseif n.kind == "tabstop" then
        local s = len
        walk(defaults[n.index] or {})
        stops[n.index] = stops[n.index] or {}
        stops[n.index][#stops[n.index] + 1] = { s, len }
      elseif n.kind == "var" then
        local v = resolve and resolve(n.name)
        if v ~= nil and v ~= "" then
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
