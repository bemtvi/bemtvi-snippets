-- The VSCode-format loader internals: `discover` indexes a collection's manifest, and
-- `load_paths` reads the indexed files and normalizes them (a string OR list `prefix` and
-- `body`, per VSCode) into `{ trigger, body, description }` entries.

local vscode = require("bemtvi-snippets.vscode")

-- Write a miniature friendly-snippets collection into `dir` and return it.
local function write_collection(dir)
  btv.await(btv.fs.write(
    dir .. "/package.json",
    btv.json.encode({
      contributes = {
        snippets = {
          { language = { "lua" }, path = "./lua.json" },
          { language = "javascript", path = "js.json" },
        },
      },
    })
  ))
  btv.await(btv.fs.write(
    dir .. "/lua.json",
    btv.json.encode({
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
  btv.await(
    btv.fs.write(
      dir .. "/js.json",
      btv.json.encode({ log = { prefix = "log", body = "console.log($1)" } })
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

btv.test.describe("bemtvi-snippets.vscode loader", function()
  btv.test.it("indexes a collection's manifest per language", function()
    local dir = write_collection(btv.test.tempdir())

    local index = btv.await(vscode.discover({ dir }, false))

    btv.test.expect(index["lua"][1]).to_be(dir .. "/lua.json")
    btv.test.expect(index["javascript"][1]).to_be(dir .. "/js.json")
  end)

  btv.test.it("maps a VSCode language id onto bemtvi's filetype name", function()
    local dir = btv.test.tempdir()
    btv.await(btv.fs.write(
      dir .. "/package.json",
      btv.json.encode({
        contributes = {
          snippets = {
            { language = "shellscript", path = "sh.json" },
            { language = "csharp", path = "cs.json" },
            { language = "typescriptreact", path = "tsx.json" },
          },
        },
      })
    ))

    local index = btv.await(vscode.discover({ dir }, false))

    -- bemtvi names these filetypes `bash` / `c_sharp` / `tsx`; indexed under VSCode's
    -- own ids they would never match a buffer and the snippets would never show.
    btv.test.expect(index["bash"] ~= nil).to_be(true)
    btv.test.expect(index["c_sharp"] ~= nil).to_be(true)
    btv.test.expect(index["tsx"] ~= nil).to_be(true)
  end)

  btv.test.it("reads + normalizes the indexed files (string / list prefix + body)", function()
    local dir = write_collection(btv.test.tempdir())
    local index = btv.await(vscode.discover({ dir }, false))

    local lua = btv.await(vscode.load_paths(index["lua"]))
    local lf = by_trigger(lua, "lf")
    btv.test.expect(lf ~= nil).to_be(true)
    -- The list `body` was joined with newlines.
    btv.test.expect(lf.body).to_be("local function ${1:name}(${2:args})\n\t$0\nend")

    -- The list `prefix` fanned out into two triggers sharing one body.
    btv.test.expect(by_trigger(lua, "req") ~= nil).to_be(true)
    btv.test.expect(by_trigger(lua, "require") ~= nil).to_be(true)

    -- The other language's file is a separate read.
    local js = btv.await(vscode.load_paths(index["javascript"]))
    btv.test.expect(by_trigger(js, "log") ~= nil).to_be(true)
  end)
end)
