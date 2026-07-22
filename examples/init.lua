-- Runnable example for nxvim-snippets.
--
--   NXVIM_CONFIG=examples nxvim examples/sample.lua
--
-- Each section has a *type-this / see-that* note.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned, and
-- adding it to the runtimepath is what makes `require("nxvim-snippets")` resolve and
-- auto-sources `plugin/`). A real config would instead use
-- `{ "davidrios/nxvim-snippets", config = ... }` + :PluginSync.
nx.plugins({
  {
    name = "nxvim-snippets",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
      local snip = require("nxvim-snippets")

      -- 1. Enable the engine + jump keys (<C-j> next, <C-k> previous by default).
      snip.setup({})

      -- 2. Route the snippet source into completion, alongside the buffer word source.
      --    (The plugin never hijacks your completion config — you opt its source in.)
      --    `min_chars` is honored PER SOURCE: snippets offer from 2 chars (so short
      --    triggers like `lf` open the menu) while buffer words wait for 3.
      nx.complete.setup({
        sources = { { "buffer", min_chars = 3 }, { "nxvim-snippets", min_chars = 2 } },
      })

      -- 3. Register a few Lua snippets.
      --    TYPE (in the sample buffer, insert mode):  lf
      --    SEE:   a completion row "lf" — accept it with <C-y> and you get
      --             local function name(args)
      --                 |
      --             end
      --           with the caret on `name`. Type a name, press <C-j> to jump to `args`,
      --           <C-j> again to land inside the body ($0).
      snip.add("lua", {
        { trigger = "lf", body = "local function ${1:name}(${2:args})\n\t$0\nend" },
        -- A mirror: type once, both `${1:M}` occurrences update as you type.
        { trigger = "req", body = 'local ${1:mod} = require("${1:mod}")$0' },
        -- A choice: <C-j>/typing picks from the alternatives' default (the first).
        { trigger = "log", body = 'print("${1|debug,info,warn|}: " .. ${2:msg})$0' },
      })

      -- 4. A global ("all") snippet using variables — offered in every buffer.
      --    TYPE:  today
      --    SEE:   the current date spliced in, e.g. 2026-07-21
      snip.add("all", {
        { trigger = "today", body = "${CURRENT_YEAR}-${CURRENT_MONTH}-${CURRENT_DATE}$0" },
      })

      -- 5. (Optional) Load a whole VSCode collection. Point this at a friendly-snippets
      --    checkout to get thousands of snippets across languages:
      --
      --    nx.await(snip.load_vscode(os.getenv("HOME") .. "/friendly-snippets"))
    end,
  },
})
