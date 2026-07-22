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
--   vscode.lua     load a VSCode-format collection over async nx.fs
--
-- Quick start (init.lua):
--   local snip = require("nxvim-snippets")
--   snip.setup({})                                  -- registers the completion source
--   snip.add("lua", { { trigger = "fn",
--     body = "local function ${1:name}(${2:args})\n\t$0\nend" } })
--   snip.load_vscode("/path/to/friendly-snippets")  -- optional: a whole collection

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
}

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

-- Load a VSCode-format snippet collection from `dir` (a friendly-snippets checkout).
-- Async: returns a promise that resolves once every contributed file is registered.
function M.load_vscode(dir)
  return vscode.load(dir, function(ft, list)
    M.add(ft, list)
  end)
end

-- setup(opts) — (re)configure and register the completion source + jump keymaps.
-- `opts.jump_next` / `opts.jump_prev` override the jump keys (or `false` to skip).
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    M.config[k] = v
  end

  source.register(function(ft)
    return M.get(ft)
  end)

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
