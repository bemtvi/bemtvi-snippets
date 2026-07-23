-- The VSCode-format loader internals: `discover` indexes a collection's manifest, and
-- `load_paths` reads the indexed files and normalizes them (a string OR list `prefix` and
-- `body`, per VSCode) into `{ trigger, body, description }` entries.

local vscode = require("nxvim-snippets.vscode")

-- Write a miniature friendly-snippets collection into `dir` and return it.
local function write_collection(dir)
  nx.await(nx.fs.write(
    dir .. "/package.json",
    nx.json.encode({
      contributes = {
        snippets = {
          { language = { "lua" }, path = "./lua.json" },
          { language = "javascript", path = "js.json" },
        },
      },
    })
  ))
  nx.await(nx.fs.write(
    dir .. "/lua.json",
    nx.json.encode({
      ["local function"] = {
        prefix = "lf",
        body = { "local function ${1:name}(${2:args})", "\t$0", "end" },
        description = "a local function",
      },
      ["require"] = {
        prefix = { "req", "require" }, -- a list prefix fans out
        body = 'local ${1:mod} = require("${2:mod}")',
      },
    })
  ))
  nx.await(
    nx.fs.write(
      dir .. "/js.json",
      nx.json.encode({ log = { prefix = "log", body = "console.log($1)" } })
    )
  )
  return dir
end

local function by_trigger(list, trigger)
  for _, s in ipairs(list) do
    if s.trigger == trigger then
      return s
    end
  end
  return nil
end

nx.test.describe("nxvim-snippets.vscode loader", function()
  nx.test.it("indexes a collection's manifest per language", function()
    local dir = write_collection(nx.test.tempdir())

    local index = nx.await(vscode.discover({ dir }, false))

    nx.test.expect(index["lua"][1]).to_be(dir .. "/lua.json")
    nx.test.expect(index["javascript"][1]).to_be(dir .. "/js.json")
  end)

  nx.test.it("reads + normalizes the indexed files (string / list prefix + body)", function()
    local dir = write_collection(nx.test.tempdir())
    local index = nx.await(vscode.discover({ dir }, false))

    local lua = nx.await(vscode.load_paths(index["lua"]))
    local lf = by_trigger(lua, "lf")
    nx.test.expect(lf ~= nil).to_be(true)
    -- The list `body` was joined with newlines.
    nx.test.expect(lf.body).to_be("local function ${1:name}(${2:args})\n\t$0\nend")

    -- The list `prefix` fanned out into two triggers sharing one body.
    nx.test.expect(by_trigger(lua, "req") ~= nil).to_be(true)
    nx.test.expect(by_trigger(lua, "require") ~= nil).to_be(true)

    -- The other language's file is a separate read.
    local js = nx.await(vscode.load_paths(index["javascript"]))
    nx.test.expect(by_trigger(js, "log") ~= nil).to_be(true)
  end)
end)
