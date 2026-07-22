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
  snip._index = nil
  snip._lazy = {}
  snip.config.friendly_snippets = true
end

nx.test.describe("nxvim-snippets lazy discovery", function()
  nx.test.it("indexes the manifest without reading snippet files", function()
    reset()
    local dir = write_collection(nx.test.tempdir())

    local index = nx.await(vscode.discover({ dir }))

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

    -- Unlike `load` (fail-loud on an explicit dir), a sweep just skips it — no error,
    -- empty index.
    local index = nx.await(vscode.discover({ dir }))
    nx.test.expect(next(index) == nil).to_be(true)
  end)

  nx.test.it("loads only the requested filetype (plus the global 'all' scope)", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.config.friendly_snippets = { dir }

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
    snip.config.friendly_snippets = { dir }

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

  nx.test.it("does nothing when auto-loading is disabled", function()
    reset()
    local dir = write_collection(nx.test.tempdir())
    snip.config.friendly_snippets = false

    nx.await(snip._ensure_lazy("lua"))
    nx.test.expect(has_trigger(snip.get("lua"), "lf")).to_be(false)
  end)
end)
