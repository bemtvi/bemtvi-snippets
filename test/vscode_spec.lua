-- The VSCode-format loader: write a miniature friendly-snippets collection to a temp
-- dir and prove it's read, normalized (string + list prefix/body), and registered per
-- language through the async nx.fs seam.

local snip = require("nxvim-snippets")
local vscode = require("nxvim-snippets.vscode")

-- Write a fake collection into `dir` and return it.
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
end

-- Find a registered snippet by trigger in a list.
local function by_trigger(list, trigger)
  for _, s in ipairs(list) do
    if s.trigger == trigger then
      return s
    end
  end
  return nil
end

nx.test.describe("nxvim-snippets.vscode loader", function()
  nx.test.it("loads a package.json collection and registers per language", function()
    snip._byft = {}
    local dir = nx.test.tempdir()
    write_collection(dir)
    nx.await(vscode.load(dir, function(ft, list)
      snip.add(ft, list)
    end))

    local lua = snip.get("lua")
    local lf = by_trigger(lua, "lf")
    nx.test.expect(lf ~= nil).to_be(true)
    -- The list `body` was joined with newlines.
    nx.test.expect(lf.body).to_be("local function ${1:name}(${2:args})\n\t$0\nend")

    -- The list `prefix` fanned out into two triggers sharing one body.
    nx.test.expect(by_trigger(lua, "req") ~= nil).to_be(true)
    nx.test.expect(by_trigger(lua, "require") ~= nil).to_be(true)

    -- The other language landed in its own bucket.
    nx.test.expect(by_trigger(snip.get("javascript"), "log") ~= nil).to_be(true)
  end)

  nx.test.it("fails loud when package.json has no snippets", function()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/package.json", nx.json.encode({ name = "empty" })))
    local ok = pcall(function()
      nx.await(vscode.load(dir, function() end))
    end)
    nx.test.expect(ok).to_be(false)
  end)
end)
