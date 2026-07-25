-- The completion-menu integration: a `nx.complete.source` that offers the registered
-- snippets for the current buffer's filetype, and expands the chosen one through the
-- session on accept.
--
-- The keystone is the item's `on_accept` (P4): the menu row carries no literal insert
-- text — accepting it hands the callback the trigger RANGE under the cursor, and the
-- callback drives `session.expand` over exactly that range. Nothing snippet-specific
-- touches the core completion engine.

local session = require("nxvim-snippets.session")

local M = {}

-- The current buffer's filetype (via the option mirror), or "".
local function buf_ft(buf)
  local ok, ft = pcall(function()
    return nx.bo[buf].filetype
  end)
  return (ok and ft) or ""
end

-- The docs-float markdown previewing a snippet completion row: its body fenced as a
-- code block (tagged with the buffer's filetype so it syntax-highlights), with any
-- `description` as a lead paragraph. So selecting a snippet row shows what it expands
-- to — the same "function docs" surface LSP items use — instead of nothing when the
-- snippet has no description. Mirrors the built-in `snippets` source's preview.
function M.preview_doc(snip, ft)
  local fenced = "```" .. ft .. "\n" .. snip.body .. "\n```"
  if snip.description and snip.description ~= "" then
    return snip.description .. "\n\n" .. fenced
  end
  return fenced
end

-- Completion items, memoized per (snippet, filetype). The source re-offers every
-- snippet of the filetype on EVERY keystroke, so building a fresh item table (and an
-- `on_accept` closure) each time churned one allocation per snippet per keypress —
-- thousands of them with a collection like friendly-snippets loaded. The item is
-- immutable and the engine only reads it, so one instance is reused.
--
-- Weak-keyed, so a snippet dropped from the registry (a reconfigure re-reads the
-- collections) takes its items with it. The items reference their own key, which
-- Lua 5.4's ephemeron tables collect correctly.
local ITEMS = setmetatable({}, { __mode = "k" })

local function item_for(snip, ft)
  local cache = ITEMS[snip]
  if not cache then
    cache = {}
    ITEMS[snip] = cache
  end
  local item = cache[ft]
  if not item then
    item = {
      text = snip.trigger,
      -- The right-aligned kind column, so a snippet row reads `Snippet` and stands
      -- apart from a buffer word / LSP item (matching the built-in `snippets` source).
      kind = "Snippet",
      -- No inline `doc`: the source's `resolve` renders the preview for the ONE row the
      -- user lands on, instead of rendering every candidate's body on every keystroke.
      _ft = ft,
      _snippet = snip,
      on_accept = function(_item, c)
        -- The callback OWNS the edit: expand over the trigger range the engine
        -- computed (P4 → P1/P2/P5 inside the session).
        session.expand(c.buf, c.start_row, c.start_col, c.end_row, c.end_col, snip.body)
      end,
    }
    cache[ft] = item
  end
  return item
end

-- register(get, min_chars, ensure) — install the source. `get(ft)` returns the snippet
-- list to offer for filetype `ft` (the caller merges ft-specific + global "all").
-- `ensure(ft)` (optional) returns a promise the source awaits before offering rows —
-- the lazy loader that pulls in a friendly-snippets language the first time it's needed
-- (a no-op once cached), so those snippets appear without any up-front bulk read.
-- `min_chars` is the source's own prefix gate (how many chars before snippets show,
-- default 2).
-- Registering **activates** the source — it joins the live `nx.complete` engine on its
-- own, so the user never lists it in `nx.complete.setup{ sources }` (that list is only
-- for overriding these defaults). Idempotent-ish: calling again re-registers the
-- same-named source (the engine keeps the latest).
function M.register(get, min_chars, ensure)
  nx.complete.source({
    -- NOT "snippets" — that name is a reserved core built-in source.
    name = "nxvim-snippets",
    -- A small per-source bias added to a row's fuzzy score (the merge is fuzzy-first,
    -- then this bias breaks near-ties) — matching the built-in `snippets` source, so an
    -- equally-good snippet trigger edges out a buffer word without burying a clearly
    -- better buffer match. Override per entry with
    -- `nx.complete.setup{ sources = { { "nxvim-snippets", priority = N } } }`.
    priority = 5,
    -- The source's own prefix gate (`snip.setup{ min_chars = … }`, default 2): snippets
    -- show from this many typed chars, so short triggers like `lf` open the menu without
    -- a buffer word's longer wait. Override per entry with
    -- `nx.complete.setup{ sources = { { "nxvim-snippets", min_chars = N } } }`.
    min_chars = min_chars or 2,
    -- Snippets are cheap in-memory data, so there's nothing to debounce — offer them
    -- as soon as the prefix changes (no lag before the row appears).
    debounce = 0,
    -- Docs on demand: the engine calls this for the row the user selects, so the
    -- expansion preview is built once per selection rather than once per candidate per
    -- keystroke.
    resolve = function(item)
      return nx.promise.resolve(M.preview_doc(item._snippet, item._ft))
    end,
    complete = function(ctx)
      -- Offer every snippet for the filetype; the engine's fuzzy matcher ranks them
      -- against `ctx.prefix` and merges them with the other sources. Returning a promise
      -- (from `nx.async`) tells the engine to wait for it before settling this gen, so
      -- the first completion in a filetype can lazily read that language's collection
      -- files before offering — every later keystroke resolves it instantly (cached).
      local ft = buf_ft(ctx.buf)
      return nx.async(function()
        if ensure then
          nx.await(ensure(ft))
        end
        for _, snip in ipairs(get(ft)) do
          ctx.push(item_for(snip, ft))
        end
      end)()
    end,
  })
end

return M
