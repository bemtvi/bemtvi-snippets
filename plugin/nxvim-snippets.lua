-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/` like a
-- neovim plugin). Registers the completion source + jump keymaps with defaults so it
-- works out of the box. `setup()` is a full reconfigure, so a user calling
-- `require("nxvim-snippets").setup({...})` from their init.lua just re-applies options.
--
-- No snippet collection is seeded here — add snippets with
-- `require("nxvim-snippets").add(ft, {...})` or load a VSCode collection with
-- `.load_vscode(dir)`. See the README.
require("nxvim-snippets").setup({})
