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

-- Registered snippets, keyed by filetype: `_byft[ft] = { { trigger, body, description }, ... }`.
-- The `"all"` bucket (VSCode's global scope) is offered for every filetype.
M._byft = {}

M.config = {
  -- Insert-mode keys to jump between tabstops. Installed by `setup`; a no-op when no
  -- session is active (so they're effectively reserved while the plugin is on). Set
  -- either to `false` in `setup{}` to not install it and map `M.jump_next/prev` yourself.
  jump_next = "<C-j>",
  jump_prev = "<C-k>",
  -- The completion source's own prefix gate: snippets show from this many typed chars.
  -- Kept low (2) so short triggers like `lf` open the menu. The source auto-joins the
  -- `nx.complete` engine with this gate — no need to list it in `nx.complete.setup`.
  min_chars = 2,
  -- Auto-discover VSCode snippet collections (e.g. friendly-snippets) on the
  -- runtimepath. Put friendly-snippets on the runtimepath — as a plugin dependency in
  -- your plugin manager — and its snippets appear in completion automatically. Nothing is
  -- read up front: only each collection's small `package.json` manifest is scanned to
  -- learn which files feed which filetype; a language's actual snippet files are read the
  -- first time a completion needs them, then cached (see `M._ensure_lazy`). Set `false`
  -- to skip the runtimepath sweep — off-runtimepath collections added with
  -- `M.add_collection` are still discovered either way.
  friendly_snippets = true,
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
-- no disk I/O. Reset by `setup` so a reconfigure re-discovers.
M._lazy = {}

-- Whether there is anything to auto-discover at all: the runtimepath sweep, or at least
-- one explicitly-added collection.
function M._discovery_on()
  return M.config.friendly_snippets ~= false or #M._collections > 0
end

-- Add one or more VSCode collection roots (a dir string, or a list of them) to the
-- auto-discovery — for a collection that isn't on the runtimepath. Lazily loaded per
-- filetype exactly like a runtimepath collection; no bodies are read until a completion
-- needs them. Drops the memoized index so the new root is picked up on the next
-- completion (call it at config time, before completions start, so already-loaded
-- filetypes see it too).
function M.add_collection(dirs)
  if type(dirs) == "string" then
    dirs = { dirs }
  elseif type(dirs) ~= "table" then
    error("nxvim-snippets.add_collection: expected a dir string or list, got " .. type(dirs))
  end
  for _, dir in ipairs(dirs) do
    M._collections[#M._collections + 1] = dir
  end
  M._index = nil
end

-- Ensure the manifest index is built (once). Unions the runtimepath sweep (unless
-- `friendly_snippets` is `false`) with the explicitly-added `_collections`.
function M._ensure_index()
  if not M._index then
    M._index = vscode.discover(M._collections, M.config.friendly_snippets ~= false)
  end
  return M._index
end

-- Lazily load the discovered VSCode snippets for filetype `ft` into `_byft`, reading
-- only that filetype's files (plus the global `"all"` bucket `M.get` merges into every
-- filetype) and only the first time — the memoized per-key promise is the cache.
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
        M._lazy[key] = vscode.load_paths(index[key] or {}):next(function(list)
          M.add(key, list)
        end)
      end
      if M._lazy[key] then
        nx.await(M._lazy[key])
      end
    end
  end)()
end

-- Validate + store a snippet list for `ft`. Each entry needs a string `trigger` and a
-- string `body`; `description` is optional. Fails loud on a bad shape (no silent skip).
function M.add(ft, list)
  if type(ft) ~= "string" then
    error("nxvim-snippets.add: filetype must be a string, got " .. type(ft))
  end
  if type(list) ~= "table" then
    error("nxvim-snippets.add: expected a list of { trigger, body } for '" .. ft .. "'")
  end
  local bucket = M._byft[ft] or {}
  for i, s in ipairs(list) do
    if type(s) ~= "table" or type(s.trigger) ~= "string" then
      error("nxvim-snippets.add: entry " .. i .. " needs a string `trigger`")
    end
    if type(s.body) ~= "string" then
      error("nxvim-snippets.add: entry '" .. s.trigger .. "' needs a string `body`")
    end
    bucket[#bucket + 1] = { trigger = s.trigger, body = s.body, description = s.description }
  end
  M._byft[ft] = bucket
end

-- The snippets to offer for filetype `ft`: its own plus the global `"all"` bucket.
function M.get(ft)
  local out = {}
  for _, s in ipairs(M._byft[ft] or {}) do
    out[#out + 1] = s
  end
  if ft ~= "all" then
    for _, s in ipairs(M._byft["all"] or {}) do
      out[#out + 1] = s
    end
  end
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

-- setup(opts) — (re)configure and register the completion source + jump keymaps.
-- `opts.jump_next` / `opts.jump_prev` override the jump keys (or `false` to skip).
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    M.config[k] = v
  end

  -- A reconfigure re-discovers: drop the memoized manifest scan and per-filetype load
  -- caches so a changed `friendly_snippets` (e.g. toggled off) takes effect.
  -- Already-registered snippets in `_byft` and added `_collections` are left in place.
  M._index = nil
  M._lazy = {}

  source.register(
    function(ft)
      return M.get(ft)
    end,
    M.config.min_chars,
    function(ft)
      return M._ensure_lazy(ft)
    end
  )

  -- Map the jump keys in BOTH Insert and Select mode: a placeholder with a default is
  -- landed on in Select mode (so typing replaces it), and the jump keys must work there
  -- too — otherwise <C-j> on a selected placeholder would fall through to Normal.
  if M.config.jump_next then
    nx.keymap.set({ "i", "s" }, M.config.jump_next, function()
      M.jump_next()
    end, { desc = "nxvim-snippets: jump to next tabstop" })
  end
  if M.config.jump_prev then
    nx.keymap.set({ "i", "s" }, M.config.jump_prev, function()
      M.jump_prev()
    end, { desc = "nxvim-snippets: jump to previous tabstop" })
  end
end

return M
