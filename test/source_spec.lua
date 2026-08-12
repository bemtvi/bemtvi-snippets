-- The completion-source integration: a registered snippet appears in the menu and, on
-- accept, expands into a live tabstop session (via the item's on_accept). This is the
-- full user-facing path — type a trigger, accept, land in the snippet.

local snip = require("bemtvi-snippets")
local source = require("bemtvi-snippets.source")

btv.test.describe("bemtvi-snippets completion row docs", function()
  btv.test.it("previews the body as markdown fenced with the buffer's filetype", function()
    local doc = source.preview_doc({ trigger = "lf", body = "local $1" }, "lua")
    btv.test.expect(doc).to_be("```lua\nlocal $1\n```")
  end)

  btv.test.it("leads with the description when the snippet has one", function()
    local snippet = { trigger = "lf", body = "local $1", description = "a local" }
    btv.test.expect(source.preview_doc(snippet, "lua")).to_be("a local\n\n```lua\nlocal $1\n```")
  end)
end)

btv.test.describe("bemtvi-snippets completion source", function()
  btv.test.before_each(function()
    snip.abort()
    snip._byft = {}
    -- `snip.setup` registers the source, which AUTO-JOINS the engine — the user just
    -- enables completion (here with its buffer default) and never routes the source.
    snip.setup({})
    btv.complete.setup({})
  end)

  btv.test.it("offers a filetype's snippet and expands it on accept", function(t)
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
    btv.test.expect(t:line(1)).to_be("for i = 1, n do end")
  end)

  btv.test.it("auto-joins an engine that never listed it", function(t)
    -- The plugin registers its source in `snip.setup` (before_each). Here the completion
    -- engine is set up with ONLY `buffer` — the snippet source is never named — yet it
    -- still contributes and expands, because registering a source activates it. This is
    -- the whole point: a user enables `btv.complete` and the snippet source just works.
    btv.complete.setup({ sources = { { "buffer" } } })
    snip.add("lua", { { trigger = "forr", body = "for ${1:i} = 1, ${2:n} do$0 end" } })
    t:cmd("enew")
    t:cmd("set filetype=lua")
    t:feed("ifo") -- a prefix that fuzzy-matches the (unlisted) snippet trigger "forr"
    t:sleep(30)
    t:feed("<C-n>")
    t:feed("<C-y>")
    t:wait_for(function()
      return snip.active()
    end)
    btv.test.expect(t:line(1)).to_be("for i = 1, n do end")
  end)

  btv.test.it("does not offer snippets from another filetype", function(t)
    snip.add("python", { { trigger = "defp", body = "def $1(): $0" } })
    t:cmd("enew")
    t:cmd("set filetype=lua") -- a lua buffer
    t:feed("idefp") -- the python trigger, typed in a lua buffer
    t:sleep(30)
    t:feed("<C-n>") -- try to select a row (there is none for this filetype)
    t:feed("<C-y>") -- accept — but nothing snippet-y is there
    -- No snippet session ever starts (the python snippet isn't offered here).
    btv.test.expect(snip.active()).to_be(false)
  end)

  btv.test.it("lazily loads an added collection on first completion", function(t)
    -- The full auto-load path THROUGH the source: add a temp VSCode collection, and
    -- prove its snippet is discovered + read on the first completion in that filetype and
    -- offered in the menu (nothing was preloaded).
    local dir = btv.test.tempdir()
    btv.await(btv.fs.write(
      dir .. "/package.json",
      btv.json.encode({
        contributes = { snippets = { { language = "lua", path = "lua.json" } } },
      })
    ))
    btv.await(btv.fs.write(
      dir .. "/lua.json",
      btv.json.encode({
        ["for range"] = { prefix = "forr", body = "for ${1:i} = 1, ${2:n} do$0 end" },
      })
    ))
    snip._byft = {}
    snip._collections = {}
    snip.setup({})
    snip.add_collection(dir)
    btv.complete.setup({})

    -- The snippet lives only on disk — nothing is registered until a completion asks.
    btv.test.expect(#snip.get("lua")).to_be(0)

    t:cmd("enew")
    t:cmd("set filetype=lua")
    t:feed("ifo") -- fuzzy-matches the not-yet-loaded trigger "forr"
    -- The first completion reads lua.json (async) before offering — give it a beat.
    t:sleep(60)
    t:feed("<C-n>")
    t:feed("<C-y>")
    t:wait_for(function()
      return snip.active()
    end)
    btv.test.expect(t:line(1)).to_be("for i = 1, n do end")
  end)

  btv.test.it("renders a selected row's docs lazily, not for every candidate", function(t)
    -- The row carries no inline `doc`: the engine asks the source's `resolve` for the
    -- ONE row the user lands on. Spy on the preview builder to prove both halves —
    -- nothing is rendered while merely offering, and selecting fires it.
    local real, calls = source.preview_doc, {}
    source.preview_doc = function(snippet, ft)
      calls[#calls + 1] = snippet.trigger
      return real(snippet, ft)
    end
    local ok, err = pcall(function()
      snip.add("lua", { { trigger = "forr", body = "for ${1:i} = 1, ${2:n} do$0 end" } })
      t:cmd("enew")
      t:cmd("set filetype=lua")
      t:feed("ifo")
      t:sleep(30)
      btv.test.expect(#calls).to_be(0) -- offering rendered no docs at all
      t:feed("<C-n>") -- select the row → the engine resolves its docs
      t:wait_for(function()
        return #calls > 0
      end)
      btv.test.expect(calls[1]).to_be("forr")
    end)
    source.preview_doc = real
    if not ok then
      error(err, 0)
    end
  end)

  btv.test.it("a snippet trigger outranks a fuzzy buffer word", function(t)
    -- Both `buffer` and the auto-joined snippet source are active; the snippet source's
    -- priority (5) must rank its rows above plain buffer words (0) so an exact trigger
    -- isn't buried. Only `buffer` is listed — the snippet source joins on its own.
    btv.complete.setup({ sources = { { "buffer", min_chars = 2 } } })
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
    btv.test.expect(snip.active()).to_be(true)
    btv.test.expect(t:line(1)).to_be("alongside LOG()")
  end)
end)
