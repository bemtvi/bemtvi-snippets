-- The completion-source integration: a registered snippet appears in the menu and, on
-- accept, expands into a live tabstop session (via the item's on_accept). This is the
-- full user-facing path — type a trigger, accept, land in the snippet.

local snip = require("nxvim-snippets")

nx.test.describe("nxvim-snippets completion source", function()
  nx.test.before_each(function()
    snip.abort()
    snip._byft = {}
    snip.setup({})
    -- Route the plugin's source into the completion engine (the user does this in
    -- their config; the plugin doesn't hijack nx.complete).
    nx.complete.setup({ sources = { { "nxvim-snippets", min_chars = 2 } } })
  end)

  nx.test.it("offers a filetype's snippet and expands it on accept", function(t)
    snip.add("lua", { { trigger = "forr", body = "for ${1:i} = 1, ${2:n} do$0 end" } })
    t:cmd("enew")
    t:cmd("set filetype=lua")
    t:feed("ifo") -- type a prefix that fuzzy-matches "forr"
    -- Let the (debounced) source populate the popup, then select + accept.
    t:sleep(30)
    t:feed("<C-n>") -- select the first row
    t:feed("<C-y>") -- accept → the item's on_accept expands the snippet
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(t:line(1)).to_be("for i = 1, n do end")
  end)

  nx.test.it("does not offer snippets from another filetype", function(t)
    snip.add("python", { { trigger = "defp", body = "def $1(): $0" } })
    t:cmd("enew")
    t:cmd("set filetype=lua") -- a lua buffer
    t:feed("idefp") -- the python trigger, typed in a lua buffer
    t:sleep(30)
    t:feed("<C-n>") -- try to select a row (there is none for this filetype)
    t:feed("<C-y>") -- accept — but nothing snippet-y is there
    -- No snippet session ever starts (the python snippet isn't offered here).
    nx.test.expect(snip.active()).to_be(false)
  end)

  nx.test.it("a snippet trigger outranks a fuzzy buffer word", function(t)
    -- Both `buffer` and the snippet source active; the snippet source's priority (90)
    -- must rank its rows above plain buffer words (10) so an exact trigger isn't buried.
    nx.complete.setup({
      sources = { { "buffer", min_chars = 2 }, { "nxvim-snippets", min_chars = 2 } },
    })
    snip.add("lua", { { trigger = "log", body = "LOG($1)$0" } })
    t:cmd("enew")
    t:cmd("set filetype=lua")
    -- `alongside` is a buffer word that fuzzy-matches `lo`; type both on one line so the
    -- prefix is `lo` with the word already present as a candidate.
    t:feed("ialongside lo")
    t:sleep(30)
    t:feed("<C-n>") -- select the FIRST (highest-priority) row
    t:feed("<C-y>") -- accept it
    -- The snippet row ranked first, so accepting it started a session (had the buffer
    -- word ranked first, `alongside` would have been inserted and no session started).
    t:wait_for(function()
      return snip.active()
    end)
    nx.test.expect(snip.active()).to_be(true)
    nx.test.expect(t:line(1)).to_be("alongside LOG()")
  end)
end)
