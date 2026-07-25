-- Load a VSCode-format snippet collection (the friendly-snippets shape) entirely in
-- Lua, over the async `nx.fs` seam — no core support for the format.
--
-- Layout: a `package.json` with `contributes.snippets = [{ language, path }, ...]`,
-- and per-language `*.json` files mapping `"name" -> { prefix, body, description }`.
-- `prefix` and `body` may each be a string OR a list of strings (VSCode allows both);
-- both are normalized here.

local M = {}

-- VSCode language id -> nxvim filetype, where they DIFFER. Identity otherwise, so most
-- languages need no entry — but a language listed here under VSCode's own id would
-- never match a buffer, and its snippets would silently never appear. (nxvim detects
-- `.sh` as `bash`, `.cs` as `c_sharp`, `.tsx` as `tsx` and `.jsx` as `javascript`.)
local LANG_TO_FT = {
  shellscript = "bash",
  csharp = "c_sharp",
  javascriptreact = "javascript",
  typescriptreact = "tsx",
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

-- Parse one snippet JSON file's contents into a flat snippet list. Raises on malformed
-- JSON — `load_paths` folds that into its per-file skip.
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

-- Read + JSON-decode `path`, as a promise. BOTH steps are part of the promise, so a
-- malformed document rejects it like an unreadable file does — the callers' `:catch`
-- then covers each equally (decoding outside the chain used to escape as a hard error
-- and sink the whole sweep).
local function read_json(path)
  return nx.fs.read_text(path):next(function(raw)
    return nx.json.decode(raw)
  end)
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
    local rel = type(entry.path) == "string" and entry.path:gsub("^%./", "") or ""
    if rel ~= "" then
      local path = dir .. "/" .. rel
      for _, lang in ipairs(langs or {}) do
        records[#records + 1] = { ft = LANG_TO_FT[lang] or lang, path = path }
      end
    end
  end
  return records
end

-- The collection roots to sweep: the LIVE runtimepath (when `include_rtp`) plus every
-- explicitly-added dir, de-duplicated. The same root reachable both ways — a collection
-- on the runtimepath that was ALSO passed to `add_collection` — must be swept once, or
-- every one of its snippets is registered twice and shows as a duplicate row.
local function collection_roots(dirs, include_rtp)
  local roots, seen = {}, {}
  local function add(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    dir = dir:gsub("(.)/+$", "%1") -- "/a/b/" and "/a/b" are one root (but "/" stays "/")
    if not seen[dir] then
      seen[dir] = true
      roots[#roots + 1] = dir
    end
  end
  if include_rtp then
    -- Each match is a `<rtp-entry>/package.json`; strip the filename to the root.
    for _, pkgpath in ipairs(nx.runtime_file("package.json", true) or {}) do
      add((pkgpath:gsub("[/\\]package%.json$", "")))
    end
  end
  for _, dir in ipairs(dirs or {}) do
    add(dir)
  end
  return roots
end

-- discover(dirs, include_rtp) -> promise of an index `{ [ft] = { path, ... }, ... }`:
-- the snippet FILES each filetype is fed by, WITHOUT reading any of them. Only the small
-- `package.json` manifest of each collection is read, so this stays cheap even for a
-- 140-file collection like friendly-snippets — the per-language file reads are deferred
-- to `load_paths` (called on demand when a completion first needs that filetype).
--
-- Sources of collection roots (unioned, de-duplicated): the LIVE runtimepath when
-- `include_rtp` is truthy (`nx.runtime_file`, how a friendly-snippets checkout added as
-- a plugin dependency is found automatically), plus every root in the explicit `dirs`
-- list. A package.json that is not a snippet collection (no `contributes.snippets`), is
-- unreadable, or is not valid JSON is silently skipped — discovery never fails loud on
-- one bad entry.
function M.discover(dirs, include_rtp)
  return nx.async(function()
    -- Every manifest read is dispatched BEFORE the first await, so the reads run
    -- concurrently rather than one round trip per runtimepath entry.
    local pending = {}
    for _, dir in ipairs(collection_roots(dirs, include_rtp)) do
      pending[#pending + 1] = {
        dir = dir,
        promise = read_json(dir .. "/package.json"):catch(function()
          return nil -- unreadable, or not JSON: not a collection we can use
        end),
      }
    end

    local index, seen = {}, {}
    for _, item in ipairs(pending) do
      for _, rec in ipairs(manifest_records(item.dir, nx.await(item.promise)) or {}) do
        local key = rec.ft .. "\0" .. rec.path
        if not seen[key] then
          seen[key] = true
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
-- files (the ones `discover` indexed for a filetype) and merge their snippets. A file
-- that is unreadable OR malformed is reported via `nx.notify` and skipped, so one bad
-- file doesn't sink the language's whole load.
function M.load_paths(paths)
  return nx.async(function()
    -- Dispatch every read up front (concurrent), then fold the results in order.
    local pending = {}
    for _, path in ipairs(paths or {}) do
      pending[#pending + 1] = {
        path = path,
        promise = nx.fs
          .read_text(path)
          :next(function(raw)
            return { snippets = parse_file(raw) }
          end)
          :catch(function(err)
            return { err = tostring(err) }
          end),
      }
    end

    local list = {}
    for _, item in ipairs(pending) do
      local result = nx.await(item.promise)
      if result.err then
        nx.notify("nxvim-snippets: could not load " .. item.path .. ": " .. result.err, "warn")
      else
        for _, s in ipairs(result.snippets) do
          list[#list + 1] = s
        end
      end
    end
    return list
  end)()
end

return M
