-- VSCode variable resolution. Date/clock values are asserted by shape (they change);
-- file/clipboard values are asserted against a known buffer / seeded register.

local variables = require("nxvim-snippets.variables")

nx.test.describe("nxvim-snippets.variables", function()
  nx.test.it("resolves CURRENT_YEAR to a 4-digit string", function()
    local y = variables.resolve("CURRENT_YEAR")
    nx.test.expect(type(y)).to_be("string")
    nx.test.expect(y:match("^%d%d%d%d$") ~= nil).to_be(true)
  end)

  nx.test.it("zero-pads month/date/clock fields", function()
    nx.test.expect(#variables.resolve("CURRENT_MONTH")).to_be(2)
    nx.test.expect(#variables.resolve("CURRENT_DATE")).to_be(2)
    nx.test.expect(#variables.resolve("CURRENT_SECOND")).to_be(2)
  end)

  nx.test.it("derives TM_FILENAME and TM_FILENAME_BASE from the buffer name", function(t)
    local dir = nx.test.tempdir()
    local path = dir .. "/widget.lua"
    nx.await(nx.fs.write(path, "x = 1\n"))
    t:cmd("edit " .. path)
    nx.test.expect(variables.resolve("TM_FILENAME")).to_be("widget.lua")
    nx.test.expect(variables.resolve("TM_FILENAME_BASE")).to_be("widget")
  end)

  nx.test.it("reads CLIPBOARD from the + register", function()
    nx.reg.set("+", "pasted text")
    nx.test.expect(variables.resolve("CLIPBOARD")).to_be("pasted text")
  end)

  nx.test.it("returns nil for an unknown variable so the default is used", function()
    nx.test.expect(variables.resolve("TOTALLY_UNKNOWN_VAR")).to_be_nil()
  end)

  nx.test.it("honors a ctx override for the selection", function()
    nx.test.expect(variables.resolve("TM_SELECTED_TEXT", { selection = "sel!" })).to_be("sel!")
  end)
end)
