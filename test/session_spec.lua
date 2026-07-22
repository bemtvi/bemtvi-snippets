-- End-to-end: expand a snippet into a live tabstop session and drive it. This is the
-- integration that proves the core primitives compose — set_text splices the body,
-- growing-gravity extmarks let each tabstop swallow typed text, on_bytes keeps mirrors
-- in sync, and nx.win.set_cursor jumps between stops. Driven through the real editor via
-- the nx.test context (t:feed types keys and settles the tick).

local snip = require("nxvim-snippets")

nx.test.describe("nxvim-snippets session", function()
  -- The --test-plugin runner doesn't source plugin/, so set up explicitly.
  nx.test.before_each(function()
    snip.abort()
    snip._byft = {}
    snip.setup({})
  end)

  nx.test.it("expands a body and fills each tabstop as you jump", function(t)
    t:cmd("enew")
    t:feed("i") -- insert mode at (0,0)
    snip.expand("wrap($1, $2)$0")
    t:wait_for(function()
      return snip.active()
    end)
    -- The body is spliced with empty tabstops.
    nx.test.expect(t:line(1)).to_be("wrap(, )")
    -- The caret jumped to $1; typing lands inside it (growing gravity).
    t:feed("a")
    nx.test.expect(t:line(1)).to_be("wrap(a, )")
    -- Jump to $2 and fill it.
    snip.jump_next()
    t:feed("b")
    nx.test.expect(t:line(1)).to_be("wrap(a, b)")
    -- Jumping onto $0 and again ends the session.
    snip.jump_next()
    snip.jump_next()
    t:wait_for(function()
      return not snip.active()
    end)
  end)

  nx.test.it("keeps mirrors in sync with the active tabstop", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("$1 and $1 again")
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(t:line(1)).to_be(" and  again")
    -- Type into the active occurrence; the mirror follows (on_bytes → set_text, so it
    -- lands on the next tick — wait for it).
    t:feed("hi")
    t:wait_for(function()
      return t:line(1) == "hi and hi again"
    end)
    nx.test.expect(t:line(1)).to_be("hi and hi again")
  end)

  nx.test.it("recomputes a tabstop transform live as you type the source", function(t)
    t:cmd("enew")
    t:feed("i")
    -- $1's text, mirrored through an upcasing transform.
    snip.expand("$1 -> ${1/(.*)/${1:/upcase}/}")
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(t:line(1)).to_be(" -> ")
    t:feed("hey")
    t:wait_for(function()
      return t:line(1) == "hey -> HEY"
    end)
    nx.test.expect(t:line(1)).to_be("hey -> HEY")
  end)

  nx.test.it("expands a placeholder body with its default text", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("if ${1:cond} then$0")
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(t:line(1)).to_be("if cond then")
  end)

  nx.test.it("a body with no tabstops just inserts and starts no session", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("plain text")
    t:wait_for(function()
      return t:line(1) == "plain text"
    end)
    nx.test.expect(snip.active()).to_be(false)
  end)

  nx.test.it("re-indents a multi-line body's continuation lines to the anchor", function(t)
    t:cmd("enew")
    t:feed("i\t") -- the trigger sits after a tab; continuation lines inherit it
    snip.expand("if $1 then\n\t$0\nend")
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(t:lines()).to_equal({ "\tif  then", "\t\t", "\tend" })
  end)

  nx.test.it("a choice tabstop opens a dropdown; picking replaces (mirrors follow)", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("${1|a,b,c|}-${1|a,b,c|}")
    t:wait_for(function()
      return snip.active()
    end)
    -- The first alternative renders as the value in both occurrences.
    nx.test.expect(t:line(1)).to_be("a-a")
    -- The dropdown (a NON-GRABBING completion popup) is open, preselected on the current
    -- value `a`: <C-n> moves to `b`, <C-y> accepts — the pick replaces both mirrors.
    t:feed("<C-n><C-y>")
    t:wait_for(function()
      return t:line(1) == "b-b"
    end)
    nx.test.expect(t:line(1)).to_be("b-b")
  end)

  nx.test.it("jump_prev at the first tabstop stays put without erroring", function(t)
    t:cmd("enew")
    t:feed("i")
    snip.expand("wrap($1, $2)$0")
    t:wait_for(function()
      return snip.active()
    end)
    -- <C-k>/jump_prev while already on the first tabstop must not crash (an earlier bug
    -- indexed `S.order[0]` → nil); the session stays live on $1.
    snip.jump_prev()
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(snip.active()).to_be(true)
    -- $1 is still the active stop: typing fills it.
    t:feed("x")
    nx.test.expect(t:line(1)).to_be("wrap(x, )")
  end)
end)
