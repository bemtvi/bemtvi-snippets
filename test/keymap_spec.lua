-- The jump keymaps themselves: that a configured key really drives the jump through
-- the editor (not just `M.jump_next()` called directly, which every other spec does),
-- and that a chord a legacy terminal can't deliver is left unmapped rather than
-- shadowing the key it would fold onto.

local snip = require("bemtvi-snippets")

-- Every LHS the plugin currently maps in Insert mode, lowercased for comparison.
local function insert_maps()
  local out = {}
  for _, m in ipairs(btv.keymap.get("i")) do
    out[(m.lhs or ""):lower()] = true
  end
  return out
end

btv.test.describe("bemtvi-snippets jump keymaps", function()
  btv.test.before_each(function()
    snip.abort()
    snip._byft = {}
    -- The test client attaches WITH the keyboard protocol, so every default key is
    -- installable; a spec that wants the legacy client overrides the mirror itself.
    btv._set_ui_caps(true, true, false)
    snip.setup({})
  end)

  btv.test.it("<C-l> jumps forward and <C-h> jumps back, like <C-j>/<C-k>", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("wrap($1, $2)$0")
    t:wait_for(function()
      return snip.active()
    end)
    -- Fill $1, then walk forward with <C-l> — the horizontal twin of <C-j>.
    t:feed("a")
    t:feed("<C-l>")
    t:feed("b")
    btv.test.expect(t:line(1)).to_be("wrap(a, b)")
    -- ...and back with <C-h>, landing on $1. A jump onto a tabstop that already has
    -- text SELECTS it (Select mode), so the next character replaces rather than appends.
    t:feed("<C-h>")
    t:feed("z")
    btv.test.expect(t:line(1)).to_be("wrap(z, b)")
    -- The vertical pair still works — the new keys are additions, not replacements.
    t:feed("<C-j>")
    t:feed("y")
    btv.test.expect(t:line(1)).to_be("wrap(z, y)")
    t:feed("<C-k>")
    t:feed("!")
    btv.test.expect(t:line(1)).to_be("wrap(!, y)")
  end)

  btv.test.it("installs a fold-prone chord only when the client can deliver it", function()
    -- Both are mapped on the protocol-capable client `before_each` declared.
    btv.test.expect(insert_maps()["<c-h>"]).to_be(true)
    btv.test.expect(insert_maps()["<c-l>"]).to_be(true)

    -- On a legacy terminal `<C-i>` IS `<Tab>` (the same fold as `<C-h>`/`<BS>`), so
    -- mapping it would swallow Tab. Configure it as the jump key with the capability
    -- off and it must be skipped — while an ordinary chord alongside it still lands.
    -- (`<A-q>` is the stand-in for "an ordinary chord": nothing else binds it, so the
    -- map this spec leaves behind can't disturb another suite.)
    btv._set_ui_caps(false, false, false)
    snip.setup({ jump_next = { "<C-i>", "<A-q>" } })
    local maps = insert_maps()
    btv.test.expect(maps["<c-i>"]).to_be(nil)
    btv.test.expect(maps["<a-q>"]).to_be(true)

    -- When a capable client attaches later (the first attach, or a daemon re-dial from
    -- a better terminal), the plugin's UIEnter handler installs what it had to skip.
    btv._set_ui_caps(true, true, false)
    btv.autocmd.exec("UIEnter", {})
    btv.test.expect(insert_maps()["<c-i>"]).to_be(true)

    -- ...and it goes back if the next client can't deliver it — a re-dial from a plain
    -- terminal must not leave a map sitting on that terminal's `<Tab>`.
    btv._set_ui_caps(false, false, false)
    btv.autocmd.exec("UIEnter", {})
    btv.test.expect(insert_maps()["<c-i>"]).to_be(nil)

    -- `M.config` is module state that outlives this file: put the defaults back so a
    -- later suite's `setup({})` doesn't inherit this spec's jump keys. `<A-q>` is not
    -- protocol-gated, so it has to be removed by hand.
    btv._set_ui_caps(true, true, false)
    snip.setup({ jump_next = { "<C-j>", "<C-l>" }, jump_prev = { "<C-k>", "<C-h>" } })
    btv.keymap.del({ "i", "s" }, "<A-q>")
  end)
end)
