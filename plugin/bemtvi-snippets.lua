-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/` like a
-- neovim plugin). Registers the completion source + jump keymaps with defaults so it
-- works out of the box. `setup()` is a full reconfigure, so a user calling
-- `require("bemtvi-snippets").setup({...})` from their init.lua just re-applies options.
--
-- No snippet collection is seeded here — add snippets with
-- `require("bemtvi-snippets").add(ft, {...})`, or point discovery at an
-- off-runtimepath VSCode collection with `.add_collection(dir)` (a collection ON the
-- runtimepath is found automatically). See `:help bemtvi-snippets`.
require("bemtvi-snippets").setup({})
