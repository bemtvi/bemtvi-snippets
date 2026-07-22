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
    return vim.bo[buf].filetype
  end)
  return (ok and ft) or ""
end

-- The docs-float markdown previewing a snippet completion row: its body fenced as a
-- code block (tagged with the buffer's filetype so it syntax-highlights), with any
-- `description` as a lead paragraph. So selecting a snippet row shows what it expands
-- to — the same "function docs" surface LSP items use — instead of nothing when the
-- snippet has no description. Mirrors the built-in `snippets` source's preview.
local function preview_doc(snip, ft)
  local fenced = "```" .. ft .. "\n" .. snip.body .. "\n```"
  if snip.description and snip.description ~= "" then
    return snip.description .. "\n\n" .. fenced
  end
  return fenced
end

-- register(get) — install the source. `get(ft)` returns the snippet list to offer for
-- filetype `ft` (the caller merges ft-specific + global "all"). Idempotent-ish: calling
-- again re-registers the same-named source (the engine keeps the latest).
function M.register(get)
  nx.complete.source({
    -- NOT "snippets" — that name is a reserved core built-in source.
    name = "nxvim-snippets",
    -- A small per-source bias added to a row's fuzzy score (the merge is fuzzy-first,
    -- then this bias breaks near-ties) — matching the built-in `snippets` source, so an
    -- equally-good snippet trigger edges out a buffer word without burying a clearly
    -- better buffer match. Override per entry with
    -- `nx.complete.setup{ sources = { { "nxvim-snippets", priority = N } } }`.
    priority = 5,
    -- Snippets are cheap in-memory data, so there's nothing to debounce — offer them
    -- as soon as the prefix changes (no lag before the row appears).
    debounce = 0,
    complete = function(ctx)
      -- Offer every snippet for the filetype; the engine's fuzzy matcher ranks them
      -- against `ctx.prefix` and merges them with the other sources.
      local ft = buf_ft(ctx.buf)
      for _, snip in ipairs(get(ft)) do
        ctx.push({
          text = snip.trigger,
          -- The right-aligned kind column, so a snippet row reads `Snippet` and stands
          -- apart from a buffer word / LSP item (matching the built-in `snippets` source).
          kind = "Snippet",
          -- Preview the expansion (body + optional description) in the docs float when
          -- this row is selected.
          doc = preview_doc(snip, ft),
          on_accept = function(_item, c)
            -- The callback OWNS the edit: expand over the trigger range the engine
            -- computed (P4 → P1/P2/P5 inside the session).
            session.expand(c.buf, c.start_row, c.start_col, c.end_row, c.end_col, snip.body)
          end,
        })
      end
    end,
  })
end

return M
