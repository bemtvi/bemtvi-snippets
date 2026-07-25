# nxvim-snippets

A snippet engine for [nxvim](https://github.com/davidrios/nxvim), built **entirely
on the native `nx.*` plugin API** — no snippet syntax lives in the editor core. It
loads VSCode-format snippet collections (e.g.
[friendly-snippets](https://github.com/rafamadriz/friendly-snippets)), offers them in
the completion menu, and expands the chosen one into a live tabstop session with
mirrors, choices, and transforms.

It is the nxvim answer to LuaSnip / vsnip: the same LSP snippet-body grammar and the
same VSCode-collection loading, re-expressed in nxvim's idiom and standing entirely
on generic core primitives (`nx.buf.set_text`, extmark gravity, `nx.buf.attach`,
`nx.complete`'s `on_accept`, `nx.win.select_range`) — none of which mentions
"snippet".

## Install

Declare it with the built-in `:Plugins` manager and run `:PluginSync`. Listing
friendly-snippets as a dependency is all it takes to get a large snippet library —
it lands on the runtimepath, and discovery finds it lazily, per filetype:

```lua
nx.plugins({
  {
    "davidrios/nxvim-snippets",
    deps = { "rafamadriz/friendly-snippets" },
    config = function()
      require("nxvim-snippets").setup({})
    end,
  },
})
```

Type a trigger, accept the completion row with `<C-y>`, and you land in the snippet
on the first tabstop. `<C-j>` / `<C-k>` jump to the next / previous one.

## Documentation

Full docs — collections and lazy loading, the snippet body grammar (tabstops,
placeholders, choices, mirrors, transforms, variables), the tabstop session, the
completion integration, and the whole API — live in the help file. The same source
renders both on GitHub and in the editor:

- In editor: `:help nxvim-snippets`
- On GitHub: [doc/nxvim-snippets.md](./doc/nxvim-snippets.md) (the help source)

## Coverage

Against the full friendly-snippets collection (9,213 snippets across 128 filetypes):
all 9,213 parse, and 9,211 (99.98%) lay out and expand. The 2 that don't use a regex
lookbehind (`(?<=…)`), which nxvim's regex engine can't compile — those fail **loud**
rather than mis-expanding.

## Trying it locally

```sh
NXVIM_CONFIG=examples nxvim examples/sample.lua
```

(run from a checkout of this repo). In insert mode type `lf`, `req`, `log`, or
`today`, accept the row with `<C-y>`, and jump with `<C-j>` / `<C-k>`.

## Development

```sh
nxvim --test-plugin .
```

Covers the parser and layout, transforms, variable resolution, the VSCode loader and
its lazy per-filetype caching, and the full session and completion paths end-to-end.

The vimdoc `doc/nxvim-snippets.txt` is **generated** from `doc/nxvim-snippets.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
