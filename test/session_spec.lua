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
end)
