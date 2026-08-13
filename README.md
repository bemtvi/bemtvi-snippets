# bemtvi-snippets

A snippet engine for [bemtvi](https://github.com/bemtvi/bemtvi), built **entirely
on the native `btv.*` plugin API** — no snippet syntax lives in the editor core. It
loads VSCode-format snippet collections (e.g.
[friendly-snippets](https://github.com/rafamadriz/friendly-snippets)), offers them in
the completion menu, and expands the chosen one into a live tabstop session with
mirrors, choices, and transforms.

It is the bemtvi answer to LuaSnip / vsnip: the same LSP snippet-body grammar and the
same VSCode-collection loading, re-expressed in bemtvi's idiom and standing entirely
on generic core primitives (`btv.buf.set_text`, extmark gravity, `btv.buf.attach`,
`btv.complete`'s `on_accept`, `btv.win.select_range`) — none of which mentions
"snippet".

## Install

Declare it with the built-in `:Plugins` manager and run `:PluginSync`. Listing
friendly-snippets as a dependency is all it takes to get a large snippet library —
it lands on the runtimepath, and discovery finds it lazily, per filetype:

```lua
btv.plugins({
  {
    "bemtvi/bemtvi-snippets",
    deps = { "rafamadriz/friendly-snippets" },
    config = function()
      require("bemtvi-snippets").setup({})
    end,
  },
})
```

Type a trigger, accept the completion row with `<C-y>`, and you land in the snippet
on the first tabstop. `<C-j>` / `<C-k>` — or `<C-l>` / `<C-h>` — jump to the next /
previous one. (`<C-h>` needs a terminal with the kitty keyboard protocol; elsewhere it
is indistinguishable from `<BS>`, so the plugin leaves it unmapped.)

## Documentation

Full docs — collections and lazy loading, the snippet body grammar (tabstops,
placeholders, choices, mirrors, transforms, variables), the tabstop session, the
completion integration, and the whole API — live in the help file. The same source
renders both on GitHub and in the editor:

- In editor: `:help bemtvi-snippets`
- On GitHub: [doc/bemtvi-snippets.md](./doc/bemtvi-snippets.md) (the help source)

## Coverage

Against the full friendly-snippets collection (9,213 snippets across 128 filetypes):
all 9,213 parse, and 9,211 (99.98%) lay out and expand. The 2 that don't use a regex
lookbehind (`(?<=…)`), which bemtvi's regex engine can't compile — those fail **loud**
rather than mis-expanding.

## Trying it locally

```sh
BEMTVI_CONFIG=examples bemtvi examples/sample.lua
```

(run from a checkout of this repo). In insert mode type `lf`, `req`, `log`, or
`today`, accept the row with `<C-y>`, and jump with `<C-j>` / `<C-k>` (or `<C-l>` /
`<C-h>`).

## Development

```sh
bemtvi --test-plugin .
```

Covers the parser and layout, transforms, variable resolution, the VSCode loader and
its lazy per-filetype caching, and the full session and completion paths end-to-end.

The vimdoc `doc/bemtvi-snippets.txt` is **generated** from `doc/bemtvi-snippets.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
