-- Load a VSCode-format snippet collection (the friendly-snippets shape) entirely in
-- Lua, over the async `nx.fs` seam — no core support for the format.
--
-- Layout: a `package.json` with `contributes.snippets = [{ language, path }, ...]`,
-- and per-language `*.json` files mapping `"name" -> { prefix, body, description }`.
-- `prefix` and `body` may each be a string OR a list of strings (VSCode allows both);
-- both are normalized here.

local M = {}

-- VSCode language id -> nxvim filetype, where they differ. Identity otherwise, so most
-- languages need no entry.
local LANG_TO_FT = {
  javascriptreact = "javascriptreact",
  typescriptreact = "typescriptreact",
  ["csharp"] = "cs",
  ["shellscript"] = "sh",
}

-- Normalize one VSCode snippet entry into zero-or-more { trigger, body, description }
-- (a list `prefix` fans out into one snippet per trigger).
local function normalize(name, entry)
  if type(entry) ~= "table" then
    return {}
  end
  local body = entry.body
  if type(body) == "table" then
    body = table.concat(body, "\n")
  end
  if type(body) ~= "string" then
    return {} -- a bodyless entry is unusable; skip rather than crash the whole file
  end
  local prefixes = entry.prefix
  if type(prefixes) == "string" then
    prefixes = { prefixes }
  elseif type(prefixes) ~= "table" then
    return {}
  end
  local out = {}
  for _, p in ipairs(prefixes) do
    if type(p) == "string" then
      out[#out + 1] = { trigger = p, body = body, description = entry.description or name }
    end
  end
  return out
end

-- Parse one snippet JSON file's contents into a flat snippet list.
local function parse_file(raw)
  local data = nx.json.decode(raw)
  local list = {}
  if type(data) == "table" then
    for name, entry in pairs(data) do
      for _, s in ipairs(normalize(name, entry)) do
        list[#list + 1] = s
      end
    end
  end
  return list
end

-- load(dir, add) -> promise. Read `dir/package.json`, then each contributed snippet
-- file, and call `add(filetype, list)` per language. Rejects (fail loud) if
-- package.json is missing / malformed; a single unreadable snippet file is reported via
-- `nx.notify` and skipped so one bad file doesn't sink the whole collection.
function M.load(dir, add)
  return nx.async(function()
    local pkg = nx.json.decode(nx.await(nx.fs.read_text(dir .. "/package.json")))
    local contributes = ((pkg or {}).contributes or {}).snippets
    if type(contributes) ~= "table" then
      error("nxvim-snippets: " .. dir .. "/package.json has no contributes.snippets")
    end
    for _, entry in ipairs(contributes) do
      local langs = entry.language
      if type(langs) == "string" then
        langs = { langs }
      end
      local rel = tostring(entry.path or ""):gsub("^%./", "")
      local path = dir .. "/" .. rel
      local ok, raw = pcall(function()
        return nx.await(nx.fs.read_text(path))
      end)
      if not ok then
        nx.notify("nxvim-snippets: could not read " .. path .. ": " .. tostring(raw), "warn")
      else
        local list = parse_file(raw)
        for _, lang in ipairs(langs or {}) do
          add(LANG_TO_FT[lang] or lang, list)
        end
      end
    end
  end)()
end

return M
