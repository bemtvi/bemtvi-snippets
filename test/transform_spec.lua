-- VSCode transforms: `${N/regex/format/opts}`. The static cases (variable transforms,
-- parse + apply) here; the LIVE tabstop-transform case is in session_spec.

local parser = require("bemtvi-snippets.parser")
local transform = require("bemtvi-snippets.transform")

local function layout(body, resolve)
  local text = parser.layout(parser.parse(body), resolve)
  return text
end

btv.test.describe("bemtvi-snippets.transform apply", function()
  btv.test.it("upcases / downcases / capitalizes a capture", function()
    local up =
      { regex = "(.*)", format = { { kind = "group", index = 1, op = "upcase" } }, options = "" }
    btv.test.expect(transform.apply("hello", up)).to_be("HELLO")
    local down =
      { regex = "(.*)", format = { { kind = "group", index = 1, op = "downcase" } }, options = "" }
    btv.test.expect(transform.apply("HELLO", down)).to_be("hello")
    local cap = {
      regex = "(.*)",
      format = { { kind = "group", index = 1, op = "capitalize" } },
      options = "",
    }
    btv.test.expect(transform.apply("hello", cap)).to_be("Hello")
  end)

  btv.test.it("pascal/camel-cases a hyphenated identifier", function()
    local pascal = {
      regex = "(.*)",
      format = { { kind = "group", index = 1, op = "pascalcase" } },
      options = "",
    }
    btv.test.expect(transform.apply("my-cool-thing", pascal)).to_be("MyCoolThing")
    local camel =
      { regex = "(.*)", format = { { kind = "group", index = 1, op = "camelcase" } }, options = "" }
    btv.test.expect(transform.apply("my-cool-thing", camel)).to_be("myCoolThing")
  end)

  btv.test.it("replaces globally with the g option", function()
    local spec = { regex = "a", format = { { kind = "text", text = "X" } }, options = "g" }
    btv.test.expect(transform.apply("banana", spec)).to_be("bXnXnX")
    -- without g, only the first match
    spec.options = ""
    btv.test.expect(transform.apply("banana", spec)).to_be("bXnana")
  end)

  btv.test.it("handles a conditional ${1:+has}", function()
    local spec = {
      regex = "(x)?",
      format = { { kind = "group", index = 1, if_text = "HAS", else_text = "NONE" } },
      options = "",
    }
    btv.test.expect(transform.apply("x", spec)).to_be("HAS")
    btv.test.expect(transform.apply("y", spec)).to_be("NONEy")
  end)
end)

btv.test.describe("bemtvi-snippets.transform via layout", function()
  btv.test.it("applies a variable transform (strip a file extension)", function()
    local text = layout("${TM_FILENAME/(.*)\\..+$/$1/}", function(name)
      return name == "TM_FILENAME" and "widget.lua" or nil
    end)
    btv.test.expect(text).to_be("widget")
  end)

  btv.test.it("renders a tabstop transform of the default value", function()
    local text = layout("${1:hi} = ${1/(.*)/${1:/upcase}/}")
    btv.test.expect(text).to_be("hi = HI")
  end)
end)
