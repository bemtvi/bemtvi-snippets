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

-- Walk `dir`'s package.json `contributes.snippets` into a flat list of
-- `{ ft = <nxvim filetype>, path = <absolute snippet-file path> }`. A `contributes`
-- entry that names several languages fans out into one record per filetype. `dir` is
-- the collection root; the returned paths are `dir`-relative resolved to absolute.
-- Returns nil for a package.json that is not a snippet collection (no
-- `contributes.snippets`) — `discover` treats that as a skip.
local function manifest_records(dir, pkg)
  local contributes = ((pkg or {}).contributes or {}).snippets
  if type(contributes) ~= "table" then
    return nil
  end
  local records = {}
  for _, entry in ipairs(contributes) do
    local langs = entry.language
    if type(langs) == "string" then
      langs = { langs }
    end
    local rel = tostring(entry.path or ""):gsub("^%./", "")
    local path = dir .. "/" .. rel
    for _, lang in ipairs(langs or {}) do
      records[#records + 1] = { ft = LANG_TO_FT[lang] or lang, path = path }
    end
  end
  return records
end

-- discover(dirs, include_rtp) -> promise of an index `{ [ft] = { path, ... }, ... }`:
-- the snippet FILES each filetype is fed by, WITHOUT reading any of them. Only the small
-- `package.json` manifest of each collection is read, so this stays cheap even for a
-- 140-file collection like friendly-snippets — the per-language file reads are deferred
-- to `load_paths` (called on demand when a completion first needs that filetype).
--
-- Sources of collection roots (unioned): the LIVE runtimepath when `include_rtp` is
-- truthy (`nx.runtime_file`, how a friendly-snippets checkout added as a plugin
-- dependency is found automatically), plus every root in the explicit `dirs` list. A
-- package.json that is not a snippet collection (no `contributes.snippets`) or is
-- unreadable is silently skipped — discovery never fails loud on one bad entry.
function M.discover(dirs, include_rtp)
  return nx.async(function()
    local roots = {}
    if include_rtp then
      -- Each match is a `<rtp-entry>/package.json`; strip the filename to the root.
      for _, pkgpath in ipairs(nx.runtime_file("package.json", true) or {}) do
        roots[#roots + 1] = (pkgpath:gsub("[/\\]package%.json$", ""))
      end
    end
    for _, dir in ipairs(dirs or {}) do
      roots[#roots + 1] = dir
    end
    local index = {}
    for _, dir in ipairs(roots) do
      local ok, raw = pcall(function()
        return nx.await(nx.fs.read_text(dir .. "/package.json"))
      end)
      if ok then
        local records = manifest_records(dir, nx.json.decode(raw))
        for _, rec in ipairs(records or {}) do
          local bucket = index[rec.ft] or {}
          bucket[#bucket + 1] = rec.path
          index[rec.ft] = bucket
        end
      end
    end
    return index
  end)()
end

-- load_paths(paths) -> promise of a flat snippet list. Read + parse the given snippet
-- files (the ones `discover` indexed for a filetype) and merge their snippets. An
-- unreadable / malformed file is reported via `nx.notify` and skipped, so one bad file
-- doesn't sink the language's whole load.
function M.load_paths(paths)
  return nx.async(function()
    local list = {}
    for _, path in ipairs(paths or {}) do
      local ok, raw = pcall(function()
        return nx.await(nx.fs.read_text(path))
      end)
      if not ok then
        nx.notify("nxvim-snippets: could not read " .. path .. ": " .. tostring(raw), "warn")
      else
        for _, s in ipairs(parse_file(raw)) do
          list[#list + 1] = s
        end
      end
    end
    return list
  end)()
end

return M
