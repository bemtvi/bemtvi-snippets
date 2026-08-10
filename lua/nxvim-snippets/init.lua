-- nxvim-snippets — a snippet engine for nxvim, built entirely on the native `nx.*`
-- plugin API. It loads VSCode-format snippet collections (friendly-snippets), offers
-- them in the completion menu, and expands the chosen one into a live tabstop session —
-- all pure Lua over five generic core primitives, with no snippet syntax baked into the
-- editor:
--
--   nx.buf.set_text        precise range edit (splice the expansion / update mirrors)
--   extmark gravity        growing tabstop ranges (right_gravity=false/end_right=true)
--   nx.buf.attach on_bytes react to edits → keep mirrors in sync; tear down on reload
--   nx.complete on_accept  the completion row that expands instead of inserting text
--   nx.win.set_cursor      jump the caret between tabstops
--
-- Module map:
--   parser.lua     the LSP/VSCode snippet-body grammar → AST → text + tabstop spans
--   variables.lua  VSCode variable resolution ($TM_FILENAME, $CURRENT_YEAR, …)
--   session.lua    the tabstop session (expand / jump / mirror sync) on the primitives
--   source.lua     the nx.complete.source integration (offer + on_accept expand)
--   vscode.lua     discover VSCode collections + lazily load them per filetype
--
-- Quick start (init.lua):
--   local snip = require("nxvim-snippets")
--   snip.setup({})                  -- registers + auto-joins the completion source
--   nx.complete.setup({})           -- enable completion however you like; snippets join
--   snip.add("lua", { { trigger = "fn",
--     body = "local function ${1:name}(${2:args})\n\t$0\nend" } })
--   snip.add_collection("/path/to/collection")  -- optional: an off-runtimepath one

local session = require("nxvim-snippets.session")
local source = require("nxvim-snippets.source")
local vscode = require("nxvim-snippets.vscode")
local parser = require("nxvim-snippets.parser")

local M = {}

-- Snippets registered BY THE USER (`M.add`), keyed by filetype:
-- `_byft[ft] = { { trigger, body, description }, ... }`. The `"all"` bucket (VSCode's
-- global scope) is offered for every filetype.
M._byft = {}

-- Snippets read from a discovered VSCode collection, in the same shape. Kept apart from
-- the user's own because they are a CACHE of what `_lazy` read: dropping the lazy-load
-- memo has to drop these with it, or the re-read appends a second copy of every snippet
-- in the collection (one duplicate completion row per trigger). User snippets are state
-- and always survive.
M._discovered = {}

M.config = {
  -- Insert-mode keys to jump between tabstops. Installed by `setup`; a no-op when no
  -- session is active (so they're effectively reserved while the plugin is on). Either
  -- may be a single key or a LIST of keys, all of which get the same jump: the defaults
  -- bind both the vertical pair (`<C-j>`/`<C-k>`, matching the completion menu's
  -- next/prev) and the horizontal one (`<C-l>`/`<C-h>`, reading as forward/back through
  -- the tabstops). Set either to `false` in `setup{}` to not install it and map
  -- `M.jump_next/prev` yourself.
  --
  -- `<C-h>` is only installed on a terminal that can actually deliver it (see
  -- `PROTOCOL_ONLY` below) — elsewhere it IS `<BS>`, and jumping instead of deleting
  -- would be worse than not binding it at all. The rest of the defaults always apply.
  jump_next = { "<C-j>", "<C-l>" },
  jump_prev = { "<C-k>", "<C-h>" },
  -- The completion source's own prefix gate: snippets show from this many typed chars.
  -- Kept low (2) so short triggers like `lf` open the menu. The source auto-joins the
  -- `nx.complete` engine with this gate — no need to list it in `nx.complete.setup`.
  min_chars = 2,
  -- Auto-discover VSCode snippet collections (e.g. friendly-snippets) on the
  -- runtimepath. Put such a collection on the runtimepath — as a plugin dependency in
  -- your plugin manager — and its snippets appear in completion automatically. Nothing is
  -- read up front: only each collection's small `package.json` manifest is scanned to
  -- learn which files feed which filetype; a language's actual snippet files are read the
  -- first time a completion needs them, then cached (see `M._ensure_lazy`). Set `false`
  -- to skip the runtimepath sweep — off-runtimepath collections added with
  -- `M.add_collection` are still discovered either way.
  discover_runtimepath = true,
}

-- Extra VSCode collection roots to auto-discover, on top of the runtimepath sweep —
-- populated by `M.add_collection`. Same lazy manifest-then-per-filetype path as the
-- runtimepath ones; this is just how you point at a collection that isn't on the rtp.
M._collections = {}

-- The one-time manifest scan (`vscode.discover`), memoized as a promise so every
-- completion shares the single sweep. Resolves to `{ [ft] = { file-path, ... } }`.
M._index = nil
-- Per-filetype lazy-load promises: `_lazy[ft]` is the (in-flight or settled) promise
-- that reads + registers `ft`'s snippet files. Memoizing it is the cache — a completion
-- keystroke after the first for a filetype awaits an already-resolved promise and does
-- no disk I/O. Dropped by `_invalidate_discovery` so a reconfigure re-discovers.
M._lazy = {}

-- Bumped every time discovery is invalidated. A load that was already in flight when
-- that happened carries the old generation and drops its result on arrival, instead of
-- landing in the freshly-cleared store alongside the re-read's copy.
M._gen = 0

-- Whether there is anything to auto-discover at all: the runtimepath sweep, or at least
-- one explicitly-added collection.
function M._discovery_on()
  return M.config.discover_runtimepath ~= false or #M._collections > 0
end

-- Add one or more VSCode collection roots (a dir string, or a list of them) to the
-- auto-discovery — for a collection that isn't on the runtimepath. Lazily loaded per
-- filetype exactly like a runtimepath collection; no bodies are read until a completion
-- needs them. Invalidates the discovery caches, so a filetype already loaded picks the
-- new root up on its next completion too (a root reachable twice is swept once).
function M.add_collection(dirs)
  if type(dirs) == "string" then
    dirs = { dirs }
  elseif type(dirs) ~= "table" then
    error("nxvim-snippets.add_collection: expected a dir string or list, got " .. type(dirs))
  end
  for _, dir in ipairs(dirs) do
    M._collections[#M._collections + 1] = dir
  end
  M._invalidate_discovery()
end

-- Drop everything derived from discovery — the memoized manifest sweep, the
-- per-filetype load promises, and the snippets those loads produced — so the next
-- completion rebuilds it from the current configuration. The three go together: keeping
-- the snippets while dropping the promise that read them is what duplicated every
-- discovered snippet on a reconfigure.
function M._invalidate_discovery()
  M._index = nil
  M._lazy = {}
  M._discovered = {}
  M._get_cache = {}
  M._gen = M._gen + 1
end

-- Ensure the manifest index is built (once). Unions the runtimepath sweep (unless
-- `discover_runtimepath` is `false`) with the explicitly-added `_collections`.
function M._ensure_index()
  if not M._index then
    M._index = vscode.discover(M._collections, M.config.discover_runtimepath ~= false)
  end
  return M._index
end

-- Lazily load the discovered VSCode snippets for filetype `ft` into `_discovered`,
-- reading only that filetype's files (plus the global `"all"` bucket `M.get` merges into
-- every filetype) and only the first time — the memoized per-key promise is the cache.
-- Returns a promise the completion source awaits before offering rows; a no-op promise
-- when there is nothing to discover.
function M._ensure_lazy(ft)
  return nx.async(function()
    if not M._discovery_on() then
      return
    end
    local index = nx.await(M._ensure_index())
    -- Load the buffer's own filetype and the always-merged `"all"` scope. Each key's
    -- read happens at most once thanks to the `_lazy[key]` promise memo.
    for _, key in ipairs({ ft, "all" }) do
      if key and key ~= "" and not M._lazy[key] then
        local gen = M._gen
        M._lazy[key] = vscode.load_paths(index[key] or {}):next(function(list)
          if M._gen == gen then
            M._store(M._discovered, key, list)
          end
        end)
      end
      if M._lazy[key] then
        nx.await(M._lazy[key])
      end
    end
  end)()
end

-- Validate + append `list` to `store[ft]`. Shared by the public `M.add` (user snippets)
-- and the lazy loader (discovered ones); each entry needs a string `trigger` and a
-- string `body`, `description` is optional. Fails loud on a bad shape (no silent skip).
function M._store(store, ft, list)
  if type(ft) ~= "string" then
    error("nxvim-snippets.add: filetype must be a string, got " .. type(ft))
  end
  if type(list) ~= "table" then
    error("nxvim-snippets.add: expected a list of { trigger, body } for '" .. ft .. "'")
  end
  local bucket = store[ft] or {}
  for i, s in ipairs(list) do
    if type(s) ~= "table" or type(s.trigger) ~= "string" then
      error("nxvim-snippets.add: entry " .. i .. " needs a string `trigger`")
    end
    if type(s.body) ~= "string" then
      error("nxvim-snippets.add: entry '" .. s.trigger .. "' needs a string `body`")
    end
    bucket[#bucket + 1] = { trigger = s.trigger, body = s.body, description = s.description }
  end
  store[ft] = bucket
  M._get_cache = {} -- the merged per-filetype lists are stale now
end

-- Register a snippet list for `ft` (the public entry point; see `_store`).
function M.add(ft, list)
  M._store(M._byft, ft, list)
end

-- The merged per-filetype lists `M.get` hands out, memoized. The completion source
-- calls `get` on EVERY keystroke, so rebuilding the merge (user + discovered, own
-- filetype + the global `"all"` scope) each time copied the whole collection —
-- thousands of entries per keypress with friendly-snippets loaded. Dropped wholesale
-- whenever a snippet is registered or discovery is invalidated.
M._get_cache = {}

-- The snippets to offer for filetype `ft`: its own plus the global `"all"` bucket,
-- user-registered ones first. The returned list is SHARED (memoized) — treat it as
-- read-only.
function M.get(ft)
  local cached = M._get_cache[ft]
  if cached then
    return cached
  end
  local out = {}
  local function append(bucket)
    for _, s in ipairs(bucket or {}) do
      out[#out + 1] = s
    end
  end
  append(M._byft[ft])
  append(M._discovered[ft])
  if ft ~= "all" then
    append(M._byft["all"])
    append(M._discovered["all"])
  end
  M._get_cache[ft] = out
  return out
end

-- Expand `body` (LSP/VSCode snippet syntax) at the cursor right now, starting a tabstop
-- session. The manual counterpart of accepting a completion row. Raises on a malformed
-- / unsupported body.
function M.expand(body)
  local pos = nx.cursor.get() -- { row (1-based), col (0-based byte) }
  local r, c = (pos[1] or 1) - 1, pos[2] or 0
  session.expand(nx.buf.current(), r, c, r, c, body)
end

-- Parse a body without expanding (exposed for tests / tooling). Raises on bad input.
function M.parse(body)
  return parser.parse(body)
end

-- Jump to the next / previous tabstop. Returns true if a session was live (so a custom
-- keymap can fall through when it wasn't).
function M.jump_next()
  return session.jump(1)
end
function M.jump_prev()
  return session.jump(-1)
end

-- Whether a tabstop session is currently active.
function M.active()
  return session.active()
end

-- End the active tabstop session, if any (drop its extmarks + detach). The manual
-- "escape the snippet" action.
function M.abort()
  session.finish()
end

-- The four chords a terminal without the kitty keyboard protocol cannot deliver: it
-- sends the named key's byte instead, and nxvim folds the mapping's LHS the same way,
-- so mapping one of these on a legacy terminal really maps `<BS>` / `<Tab>` / `<CR>` /
-- `<Esc>`. Keyed by the canonical spellings `nx.keymap.set` accepts, lowercased.
local PROTOCOL_ONLY = {
  ["<c-h>"] = true,
  ["<c-i>"] = true,
  ["<c-m>"] = true,
  ["<c-[>"] = true,
}

-- Whether `key` can be installed right now: either it is an ordinary chord, or the
-- attached client speaks the keyboard protocol and can tell it from its named twin.
local function key_deliverable(key)
  if not PROTOCOL_ONLY[key:lower()] then
    return true
  end
  return nx.ui.caps().keyboard_protocol
end

-- The keys this plugin has actually mapped, so a protocol-only chord can be taken back
-- when the client changes — and only ever one of OUR maps, never a key the user bound.
local installed = {}

-- Install one jump action on `keys`, which is `false` (skip), a single key, or a list of
-- keys that all perform the same jump. A protocol-only chord the current client can't
-- deliver is skipped — and unmapped again if an earlier client could, since `setup`
-- re-runs this on every `UIEnter`: attaching from a better terminal (or a daemon re-dial
-- from a worse one) moves the key in the right direction either way.
local function map_jump(keys, action, desc)
  if not keys then
    return
  end
  for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
    if key_deliverable(key) then
      nx.keymap.set({ "i", "s" }, key, function()
        action()
      end, { desc = desc })
      installed[key] = true
    elseif installed[key] then
      nx.keymap.del({ "i", "s" }, key)
      installed[key] = nil
    end
  end
end

-- Install both jump directions for the config in force. Idempotent — re-running
-- re-sets the same LHSs — so it is safe to repeat per `UIEnter`.
local function install_jump_keys()
  -- Map the jump keys in BOTH Insert and Select mode: a placeholder with a default is
  -- landed on in Select mode (so typing replaces it), and the jump keys must work there
  -- too — otherwise <C-j> on a selected placeholder would fall through to Normal.
  map_jump(M.config.jump_next, M.jump_next, "nxvim-snippets: jump to next tabstop")
  map_jump(M.config.jump_prev, M.jump_prev, "nxvim-snippets: jump to previous tabstop")
end

-- `UIEnter` is armed once per session, not once per `setup` — the handler reads
-- `M.config` when it runs, so a later reconfigure needs no second subscription.
M._uienter_armed = M._uienter_armed or false

-- setup(opts) — (re)configure and register the completion source + jump keymaps.
-- `opts.jump_next` / `opts.jump_prev` override the jump keys — one key, a list of keys
-- that all jump the same way, or `false` to install none and map `M.jump_next/prev`
-- yourself. A key a legacy terminal can't deliver (`<C-h>` and friends) is installed
-- only once a client that can attaches; see `PROTOCOL_ONLY`.
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    M.config[k] = v
  end

  -- A reconfigure re-discovers: drop the memoized manifest scan, the per-filetype load
  -- promises, and the snippets they produced, so a changed `discover_runtimepath` (e.g.
  -- toggled off) takes effect and the re-read replaces rather than duplicates.
  -- User-registered snippets (`_byft`) and added `_collections` are left in place.
  M._invalidate_discovery()

  source.register(
    function(ft)
      return M.get(ft)
    end,
    M.config.min_chars,
    function(ft)
      return M._ensure_lazy(ft)
    end
  )

  install_jump_keys()
  -- The config (and this `setup`) runs before any client attaches, so a protocol-only
  -- chord like `<C-h>` can't be judged yet: re-run once the client is known.
  if not M._uienter_armed then
    M._uienter_armed = true
    nx.on("UIEnter", {}, function()
      install_jump_keys()
    end)
  end
end

return M
