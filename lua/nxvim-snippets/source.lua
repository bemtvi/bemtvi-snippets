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

-- register(get) — install the source. `get(ft)` returns the snippet list to offer for
-- filetype `ft` (the caller merges ft-specific + global "all"). Idempotent-ish: calling
-- again re-registers the same-named source (the engine keeps the latest).
function M.register(get)
  nx.complete.source({
    -- NOT "snippets" — that name is a reserved core built-in source.
    name = "nxvim-snippets",
    -- Snippets are cheap in-memory data, so there's nothing to debounce — offer them
    -- as soon as the prefix changes (no lag before the row appears).
    debounce = 0,
    complete = function(ctx)
      -- Offer every snippet for the filetype; the engine's fuzzy matcher ranks them
      -- against `ctx.prefix` and merges them with the other sources.
      for _, snip in ipairs(get(buf_ft(ctx.buf))) do
        ctx.push({
          text = snip.trigger,
          -- The right-aligned kind column, so a snippet row reads `Snippet` and stands
          -- apart from a buffer word / LSP item (matching the built-in `snippets` source).
          kind = "Snippet",
          doc = snip.description,
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
