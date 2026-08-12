-- VSCode variable resolution. Date/clock values are asserted by shape (they change);
-- file/clipboard values are asserted against a known buffer / seeded register.

local variables = require("bemtvi-snippets.variables")

btv.test.describe("bemtvi-snippets.variables", function()
  btv.test.it("resolves CURRENT_YEAR to a 4-digit string", function()
    local y = variables.resolve("CURRENT_YEAR")
    btv.test.expect(type(y)).to_be("string")
    btv.test.expect(y:match("^%d%d%d%d$") ~= nil).to_be(true)
  end)

  btv.test.it("zero-pads month/date/clock fields", function()
    btv.test.expect(#variables.resolve("CURRENT_MONTH")).to_be(2)
    btv.test.expect(#variables.resolve("CURRENT_DATE")).to_be(2)
    btv.test.expect(#variables.resolve("CURRENT_SECOND")).to_be(2)
  end)

  btv.test.it("derives TM_FILENAME and TM_FILENAME_BASE from the buffer name", function(t)
    local dir = btv.test.tempdir()
    local path = dir .. "/widget.lua"
    btv.await(btv.fs.write(path, "x = 1\n"))
    t:cmd("edit " .. path)
    btv.test.expect(variables.resolve("TM_FILENAME")).to_be("widget.lua")
    btv.test.expect(variables.resolve("TM_FILENAME_BASE")).to_be("widget")
  end)

  btv.test.it("reads CLIPBOARD from the + register", function()
    btv.reg.set("+", "pasted text")
    btv.test.expect(variables.resolve("CLIPBOARD")).to_be("pasted text")
  end)

  btv.test.it("derives TM_CURRENT_WORD from the word under the cursor", function(t)
    t:cmd("enew")
    t:feed("ihello world<Esc>") -- the caret rests on the `d` of `world`
    btv.test.expect(variables.resolve("TM_CURRENT_WORD")).to_be("world")
  end)

  btv.test.it("resolves WORKSPACE_FOLDER to a directory and WORKSPACE_NAME to its base", function(t)
    local dir = btv.test.tempdir()
    local path = dir .. "/widget.lua"
    btv.await(btv.fs.write(path, "x = 1\n"))
    t:cmd("edit " .. path)
    local folder = variables.resolve("WORKSPACE_FOLDER")
    -- An absolute DIRECTORY (the workspace root, else the cwd) — never the file name.
    btv.test.expect(folder:sub(1, 1)).to_be("/")
    btv.test.expect(folder:match("widget%.lua$")).to_be_nil()
    btv.test.expect(variables.resolve("WORKSPACE_NAME")).to_be(folder:match("([^/]+)$"))
  end)

  btv.test.it("RANDOM is six digits and actually varies between calls", function()
    local seen, distinct = {}, 0
    for _ = 1, 20 do
      local v = variables.resolve("RANDOM")
      btv.test.expect(v:match("^%d%d%d%d%d%d$") ~= nil).to_be(true)
      if not seen[v] then
        seen[v], distinct = true, distinct + 1
      end
    end
    btv.test.expect(distinct > 1).to_be(true)
    -- RANDOM_HEX likewise: six hex digits, not a clock reading.
    btv.test.expect(variables.resolve("RANDOM_HEX"):match("^%x%x%x%x%x%x$") ~= nil).to_be(true)
  end)

  btv.test.it("resolves LINE_COMMENT from the buffer's 'commentstring'", function(t)
    t:cmd("enew")
    t:cmd("set commentstring=--\\ %s")
    btv.test.expect(variables.resolve("LINE_COMMENT")).to_be("--")
    -- A line-comment template has no block form, so those stay unknown (⇒ the
    -- snippet's own default).
    btv.test.expect(variables.resolve("BLOCK_COMMENT_START")).to_be_nil()
  end)

  btv.test.it("resolves the block-comment pair from a wrapping 'commentstring'", function(t)
    t:cmd("enew")
    t:cmd("set commentstring=/*\\ %s\\ */")
    btv.test.expect(variables.resolve("BLOCK_COMMENT_START")).to_be("/*")
    btv.test.expect(variables.resolve("BLOCK_COMMENT_END")).to_be("*/")
  end)

  btv.test.it("returns nil for an unknown variable so the default is used", function()
    btv.test.expect(variables.resolve("TOTALLY_UNKNOWN_VAR")).to_be_nil()
  end)

  btv.test.it("honors a ctx override for the selection", function()
    btv.test.expect(variables.resolve("TM_SELECTED_TEXT", { selection = "sel!" })).to_be("sel!")
  end)
end)
