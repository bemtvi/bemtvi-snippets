-- Lazy discovery + per-filetype loading of VSCode collections (the friendly-snippets
-- integration). Proves that adding a collection to the runtimepath makes it available
-- WITHOUT reading every snippet file up front: `discover` indexes only the manifest, and
-- a language's files are read the first time a completion asks for that filetype, then
-- cached.

local snip = require("nxvim-snippets")
local vscode = require("nxvim-snippets.vscode")

-- Write a miniature VSCode collection into `dir`: a `global.json` scoped to the "all"
-- language (VSCode's global scope), a `lua.json`, and a `python.json`, plus the
-- package.json manifest that points at them.
local function write_collection(dir)
  nx.await(nx.fs.write(
    dir .. "/package.json",
    nx.json.encode({
      contributes = {
        snippets = {
          { language = { "plaintext", "all" }, path = "./global.json" },
          { language = "lua", path = "lua.json" },
          { language = "python", path = "python.json" },
        },
      },
    })
  ))
  nx.await(
    nx.fs.write(
      dir .. "/global.json",
      nx.json.encode({ todo = { prefix = "todo", body = "TODO($1): $0" } })
    )
  )
  nx.await(nx.fs.write(
    dir .. "/lua.json",
    nx.json.encode({
      ["local function"] = {
        prefix = "lf",
        body = "local function ${1:name}(${2:args})\n\t$0\nend",
      },
    })
  ))
  nx.await(
    nx.fs.write(
      dir .. "/python.json",
      nx.json.encode({ ["def"] = { prefix = "def", body = "def ${1:name}():\n\t$0" } })
    )
  )
  return dir
end

local function has_trigger(list, trigger)
  for _, s in ipairs(list) do
    if s.trigger == trigger then
      return true
    end
  end
  return false
end

-- Restore the module to a clean slate between cases (its state is a singleton).
local function reset()
  snip._byft = {}
  snip._collections = {}
  snip.config.discover_runtimepath = true
  snip._invalidate_discovery() -- the manifest index, the per-ft loads, and what they read
end

-- How many entries in `list` carry `trigger`.
local function count_trigger(list, trigger)
  local n = 0
  for _, s in ipairs(list) do
    if s.trigger == trigger then
      n = n + 1
    end
  end
  return n
end

nx.test.describe("nxvim-snippets lazy discovery", function()
  nx.test.it("indexes the manifest without reading snippet files", function()
    reset()
    local dir = write_collection(nx.test.tempdir())

    local index = nx.await(vscode.discover({ dir }, false))

    -- The index maps each filetype to its snippet FILE(S) — the "all" scope and each
    -- language, resolved to absolute paths under the collection root.
    nx.test.expect(index["lua"] ~= nil).to_be(true)
    nx.test.expect(index["lua"][1]).to_be(dir .. "/lua.json")
    nx.test.expect(index["python"] ~= nil).to_be(true)
    nx.test.expect(index["all"] ~= nil).to_be(true)
    nx.test.expect(index["plaintext"] ~= nil).to_be(true)

    -- Crucially, discovering read NO snippet bodies — nothing is registered yet.
    nx.test.expect(has_trigger(snip.get("lua"), "lf")).to_be(false)
  end)

  nx.test.it("skips a runtimepath package.json that is not a snippet collection", function()
    reset()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/package.json", nx.json.encode({ name = "not-a-collection" })))

    -- A package.json that is not a snippet collection is silently skipped — no error,
    -- empty index.
    local index = nx.await(vscode.discover({ dir }, false))
    nx.test.expect(next(index) == nil).to_be(true)
  end)

  nx.test.it("loads only the requested filetype (plus the global 'all' scope)", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.add_collection(dir)

    nx.await(snip._ensure_lazy("lua"))

    -- Lua's own snippet is registered …
    nx.test.expect(has_trigger(snip.get("lua"), "lf")).to_be(true)
    -- … and the global "all" scope is merged into every filetype (M.get merges "all").
    nx.test.expect(has_trigger(snip.get("lua"), "todo")).to_be(true)
    -- … but python's file was NOT read — it's a different language and wasn't asked for.
    nx.test.expect(has_trigger(snip.get("python"), "def")).to_be(false)
    -- The still-global snippet does reach python (the "all" bucket), but python's own
    -- language file stayed unread.
    nx.test.expect(has_trigger(snip.get("python"), "todo")).to_be(true)
  end)

  nx.test.it("caches per filetype — a second load is memoized, not re-read", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.add_collection(dir)

    nx.await(snip._ensure_lazy("lua"))
    local first = snip._lazy["lua"]
    nx.test.expect(first ~= nil).to_be(true)
    local count_after_first = #snip.get("lua")

    -- A second ensure awaits the SAME memoized promise and adds nothing new — no
    -- duplicate registration, so the count is unchanged.
    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(snip._lazy["lua"]).to_be(first)
    nx.test.expect(#snip.get("lua")).to_be(count_after_first)
  end)

  nx.test.it("a reconfigure re-discovers without duplicating what it already read", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.add_collection(dir)
    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(count_trigger(snip.get("lua"), "lf")).to_be(1)

    -- `setup` drops the discovery caches so a changed config re-discovers. The
    -- re-read must REPLACE the discovered snippets, not append a second copy of
    -- every one of them (a duplicated row for every trigger in the collection).
    snip.setup({})
    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(count_trigger(snip.get("lua"), "lf")).to_be(1)
    nx.test.expect(count_trigger(snip.get("lua"), "todo")).to_be(1)
  end)

  nx.test.it("the same collection root added twice yields one copy of each snippet", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.add_collection(dir)
    snip.add_collection(dir) -- e.g. also reachable via the runtimepath

    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(count_trigger(snip.get("lua"), "lf")).to_be(1)
  end)

  nx.test.it("user-added snippets survive a reconfigure", function()
    reset()
    snip.add("lua", { { trigger = "mine", body = "$0" } })
    snip.setup({})
    nx.test.expect(count_trigger(snip.get("lua"), "mine")).to_be(1)
  end)

  nx.test.it("skips a collection whose package.json is malformed JSON", function()
    reset()
    local bad = nx.test.tempdir()
    nx.await(nx.fs.write(bad .. "/package.json", "{ this is not json"))
    local good = write_collection(nx.test.tempdir())

    -- One unparseable manifest must not sink the sweep: the good collection is still
    -- indexed (discovery is documented as skipping a bad entry silently).
    local index = nx.await(vscode.discover({ bad, good }, false))
    nx.test.expect(index["lua"] ~= nil).to_be(true)
  end)

  nx.test.it("skips a malformed snippet file without sinking the language", function()
    reset()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/broken.json", "{ nope"))
    nx.await(nx.fs.write(dir .. "/ok.json", nx.json.encode({ t = { prefix = "ok", body = "ok" } })))

    -- `load_paths` reports the bad file and carries on with the rest.
    local list = nx.await(vscode.load_paths({ dir .. "/broken.json", dir .. "/ok.json" }))
    nx.test.expect(has_trigger(list, "ok")).to_be(true)
  end)

  nx.test.it("does nothing when discovery is off and no collection is added", function()
    reset()
    snip.config.discover_runtimepath = false -- no runtimepath sweep, no added collections

    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(has_trigger(snip.get("lua"), "lf")).to_be(false)
  end)

  nx.test.it("add_collection loads even with the runtimepath sweep off", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    -- discover_runtimepath=false disables only the rtp sweep; an explicitly-added
    -- collection is still discovered and lazy-loaded.
    snip.config.discover_runtimepath = false
    snip.add_collection(dir)

    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(has_trigger(snip.get("lua"), "lf")).to_be(true)
  end)
end)
