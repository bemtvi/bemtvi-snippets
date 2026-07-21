-- VSCode snippet TRANSFORMS: `${N/regex/format/options}` (and the variable form
-- `${VAR/regex/format/}`). The regex runs on the source value (a tabstop's current text
-- or a variable's value) and `format` builds the replacement, with capture references
-- and case operations.
--
-- The regex itself runs on nxvim's native engine (`nx.regex`, the vendored regexp
-- engine) rather than anything hand-rolled — VSCode's syntax is JS/PCRE-ish and maps
-- onto the "pcre" dialect. Only the `format` mini-language (`$1`, `${1:/upcase}`,
-- `${1:+if}`, `${1:?a:b}`, …) is interpreted here.
--
-- The parser produces the `{ regex, format, options }` spec (format already parsed into
-- nodes); this module applies it. A tabstop transform is applied LIVE by the session as
-- the source tabstop changes; a variable transform is applied once at expand.

local M = {}

-- Case operation on a captured string (VSCode's `/upcase` etc.).
local function apply_op(s, op)
  if s == nil then
    s = ""
  end
  if op == "upcase" then
    return s:upper()
  elseif op == "downcase" then
    return s:lower()
  elseif op == "capitalize" then
    return s:sub(1, 1):upper() .. s:sub(2)
  elseif op == "pascalcase" then
    return (
      s:gsub("[-_%s]*([%w])([%w]*)", function(a, b)
        return a:upper() .. b:lower()
      end)
    )
  elseif op == "camelcase" then
    local first = true
    return (
      s:gsub("[-_%s]*([%w])([%w]*)", function(a, b)
        if first then
          first = false
          return a:lower() .. b:lower()
        end
        return a:upper() .. b:lower()
      end)
    )
  end
  return s
end

-- Render one format `group` node against the capture table (`caps[0]` the whole match,
-- `caps[N]` group N or nil when the group didn't participate).
local function render_group(node, caps)
  local g = caps[node.index]
  local matched = g ~= nil and g ~= ""
  if node.if_text ~= nil and node.else_text ~= nil then
    return matched and node.if_text or node.else_text -- ${N:?if:else}
  elseif node.if_text ~= nil then
    return matched and node.if_text or "" -- ${N:+if}
  elseif node.else_text ~= nil then
    return matched and g or node.else_text -- ${N:-else} / ${N:else}
  elseif node.op then
    return apply_op(g, node.op) -- ${N:/upcase}
  end
  return g or "" -- $N / ${N}
end

-- Render the parsed `format` node list against one match's captures.
local function render_format(format, caps)
  local out = {}
  for _, n in ipairs(format) do
    if n.kind == "text" then
      out[#out + 1] = n.text
    else
      out[#out + 1] = render_group(n, caps)
    end
  end
  return table.concat(out)
end

-- apply(value, spec) -> string. `spec = { regex, format, options }`. Runs `regex` over
-- `value` (globally when the options contain `g`, case-insensitively for `i`) and
-- replaces each match with the rendered `format`; unmatched spans pass through. Raises
-- (fail loud) if the regex doesn't compile.
function M.apply(value, spec)
  value = value or ""
  local options = spec.options or ""
  local re = nx.regex(spec.regex, { engine = "pcre", ignorecase = options:find("i") ~= nil })
  local global = options:find("g") ~= nil

  local out, pos, n = {}, 1, #value
  while pos <= n + 1 do
    local m = { re:find(value, pos) } -- { start, end, cap1, cap2, ... } or {}
    local s, e = m[1], m[2]
    if not s then
      break
    end
    out[#out + 1] = value:sub(pos, s - 1) -- text before the match
    local caps = { [0] = value:sub(s, e) }
    for i = 3, #m do
      caps[i - 2] = m[i]
    end
    out[#out + 1] = render_format(spec.format, caps)
    if e < s then
      -- zero-width match: emit the char at `s` and step past it, or we'd loop forever.
      out[#out + 1] = value:sub(s, s)
      pos = s + 1
    else
      pos = e + 1
    end
    if not global then
      break
    end
  end
  out[#out + 1] = value:sub(pos)
  return table.concat(out)
end

return M
