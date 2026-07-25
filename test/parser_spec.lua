-- The snippet-body parser + layout: pure logic, no editor state. Covers tabstops,
-- placeholders, choices, mirrors, variables, escapes, and the loud transform refusal.

local parser = require("nxvim-snippets.parser")

-- Lay out `body` with an optional variable resolver and return `text, stops`.
local function layout(body, resolve)
  return parser.layout(parser.parse(body), resolve)
end

nx.test.describe("nxvim-snippets.parser layout", function()
  nx.test.it("places an empty tabstop as a zero-width span", function()
    local text, stops = layout("hello $1 world")
    nx.test.expect(text).to_be("hello  world")
    nx.test.expect(stops[1][1][1]).to_be(6)
    nx.test.expect(stops[1][1][2]).to_be(6)
  end)

  nx.test.it("renders a placeholder's default text and spans it", function()
    local text, stops = layout("${1:name}")
    nx.test.expect(text).to_be("name")
    nx.test.expect(stops[1][1][1]).to_be(0)
    nx.test.expect(stops[1][1][2]).to_be(4)
  end)

  nx.test.it("mirrors render the same default and each occurrence is spanned", function()
    local text, stops = layout("${1:x} = $1")
    nx.test.expect(text).to_be("x = x")
    nx.test.expect(#stops[1]).to_be(2)
    nx.test.expect(stops[1][2][1]).to_be(4) -- second occurrence starts at byte 4
    nx.test.expect(stops[1][2][2]).to_be(5)
  end)

  nx.test.it("uses a choice's first alternative as the default", function()
    local text = layout("${1|alpha,beta|}")
    nx.test.expect(text).to_be("alpha")
  end)

  nx.test.it("resolves a variable through the resolver", function()
    local text = layout("$FOO bar", function(name)
      return name == "FOO" and "RESOLVED" or nil
    end)
    nx.test.expect(text).to_be("RESOLVED bar")
  end)

  nx.test.it("falls back to a variable's default when unresolved", function()
    local text = layout("${FOO:fallback}", function()
      return nil
    end)
    nx.test.expect(text).to_be("fallback")
  end)

  nx.test.it("records the final $0 stop", function()
    local _text, stops = layout("a$0b")
    nx.test.expect(stops[0][1][1]).to_be(1)
  end)

  nx.test.it("honors \\$ and \\} escapes as literal text", function()
    local text, stops = layout("cost is \\$5 \\} $1")
    nx.test.expect(text).to_be("cost is $5 } ")
    nx.test.expect(stops[1] ~= nil).to_be(true)
  end)

  nx.test.it("resolves a variable nested in a placeholder default", function()
    local text = layout("${1:${NAME:doc}}", function(name)
      return name == "NAME" and "hi" or nil
    end)
    nx.test.expect(text).to_be("hi")
  end)

  nx.test.it("treats an unrecognized ${...} as literal text (VSCode compat)", function()
    -- A hyphen isn't a legal variable char; terraform snippets use `${x-y}` literally.
    local text = layout('x = "${ami-name}"')
    nx.test.expect(text).to_be('x = "${ami-name}"')
  end)
end)

nx.test.describe("nxvim-snippets.parser transforms", function()
  nx.test.it("parses a tabstop transform into a spec", function()
    local ast = parser.parse("${1/(.*)/${1:/upcase}/g}")
    nx.test.expect(ast[1].kind).to_be("tabstop")
    nx.test.expect(ast[1].transform.regex).to_be("(.*)")
    nx.test.expect(ast[1].transform.options).to_be("g")
    nx.test.expect(ast[1].transform.format[1].op).to_be("upcase")
  end)
end)

nx.test.describe("nxvim-snippets.parser refusals", function()
  nx.test.it("rejects an unterminated ${", function()
    nx.test
      .expect(function()
        parser.parse("${1:oops")
      end)
      .to_error()
  end)

  nx.test.it("rejects a transform format group with no capture index", function()
    -- `${:/upcase}` names no group — rendering it would silently produce nothing, so
    -- it fails loud instead.
    nx.test
      .expect(function()
        parser.parse("${1/(.*)/${:/upcase}/}")
      end)
      .to_error()
  end)
end)
