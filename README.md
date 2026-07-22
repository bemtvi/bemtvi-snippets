# nxvim-snippets

A snippet engine for [nxvim](../../nxvim), built **entirely on the native `nx.*`
plugin API** — no snippet syntax lives in the editor core. It loads
VSCode-format snippet collections (e.g. [friendly-snippets]), offers them in the
completion menu, and expands the chosen one into a live tabstop session with
mirrors.

It is the nxvim answer to LuaSnip / vsnip: the same LSP snippet-body grammar and
the same VSCode-collection loading, re-expressed in nxvim's idiom and standing
entirely on five generic core primitives.

## Why it's a plugin (and what it stands on)

nxvim's core stays bare: it grows *generic* text-editing seams, and features like
this snippet engine are plain Lua on top. Five primitives make it possible — none
of them mentions "snippet":

| Primitive | Used for |
| --- | --- |
| `nx.buf.set_text` | splice the expansion over the trigger word; update mirrors inline |
| extmark **gravity** (`right_gravity=false` / `end_right_gravity=true`) | anchor each tabstop as a *growing* range so typed text is swallowed, not pushed outside |
| `nx.buf.attach{ on_bytes }` | react to each edit to keep mirrors in sync; tear down on a reload |
| `nx.complete.source` item `on_accept` | the completion row that *expands* instead of inserting literal text |
| `nx.win.set_cursor` | jump the caret between tabstops |

See `docs/specs/2026-07-21-snippet-engine-primitives.md` in the nxvim repo for the
design.

## Install

Put the repo on your `runtimepath` (via your plugin manager, or `nx.plugins`).
`plugin/nxvim-snippets.lua` auto-registers the completion source and jump keymaps.

## Quick start

```lua
local snip = require("nxvim-snippets")
snip.setup({})

-- Route the source into your completion engine (the plugin does NOT hijack it):
nx.complete.setup({ sources = { { "buffer" }, { "nxvim-snippets" } } })

-- Add snippets inline …
snip.add("lua", {
  { trigger = "lf", body = "local function ${1:name}(${2:args})\n\t$0\nend" },
})

-- … or load a whole VSCode collection (async — returns a promise):
nx.await(snip.load_vscode("/path/to/friendly-snippets"))
```

Type a trigger, accept the completion row (`<C-y>`), and you land in the snippet
with the caret on the first tabstop. `<C-j>` / `<C-k>` jump to the next / previous
tabstop (configurable).

## Snippet body grammar

The LSP / VSCode syntax:

| Form | Meaning |
| --- | --- |
| `$1` `${1}` | a tabstop (`$0` is the final one) |
| `${1:default}` | a placeholder (may nest) |
| `${1\|a,b,c\|}` | a choice — landing on it opens a dropdown of the alternatives to pick from |
| a repeated `$1` | a mirror — every occurrence renders index 1's text |
| `$TM_FILENAME` `${CURRENT_YEAR}` | a variable (resolved at expand) |
| `${VAR:fallback}` | a variable with a default |
| `${1/regex/format/opts}` | a transform (live for a tabstop, static for a variable) |
| `\$` `\}` `\\` | escapes |

**Transforms** run the regex on nxvim's native engine (`nx.regex`) and build the
replacement from the `format` mini-language: `$1` / `${1}` group references,
`${1:/upcase}` `/downcase` `/capitalize` `/pascalcase` `/camelcase` case ops,
`${1:+if}` / `${1:-else}` / `${1:?if:else}` conditionals, and the `g` / `i`
options. A tabstop transform (`${1/…/…/}`) recomputes **live** as you type the
source tabstop.

Variables resolved: the `CURRENT_*` date/clock family, `TM_FILENAME*` /
`TM_DIRECTORY` / `TM_FILEPATH`, `TM_LINE_NUMBER` / `TM_LINE_INDEX`,
`TM_CURRENT_LINE`, `TM_SELECTED_TEXT`, `CLIPBOARD`, `UUID`, `RANDOM`. An unknown
variable falls back to its `${VAR:default}` (or empty), matching VSCode.

## API

- `snip.setup(opts)` — register the source + jump keymaps. `opts.jump_next` /
  `opts.jump_prev` set the jump keys (or `false` to skip and map the functions
  yourself).
- `snip.add(ft, list)` — register `{ trigger, body, description? }` entries for a
  filetype. The `"all"` filetype is offered for every buffer (VSCode's global scope).
- `snip.load_vscode(dir)` — load a VSCode-format collection; returns a promise.
- `snip.expand(body)` — expand a body at the cursor right now.
- `snip.jump_next()` / `snip.jump_prev()` — jump tabstops (return whether a session
  was live, so a custom keymap can fall through).
- `snip.abort()` — end the active session.
- `snip.active()` — whether a session is live.

## Coverage

Against the full **friendly-snippets** collection (9,422 snippets across 127
filetypes): **all 9,422 parse, and 9,420 (99.98%) lay out and expand**. The 2 that
don't use a regex **lookbehind** (`(?<=…)`), which nxvim's regex engine (the Rust
`regex` crate) can't compile — those **fail loud** with a clear error rather than
mis-expanding.

Remaining scaffold-level limits: a placeholder's default text isn't auto-*selected*
(nxvim has no vim-style Select mode), so jumping to `${1:default}` places the caret
at its start rather than selecting the word. Continuation lines aren't re-indented
to the anchor.

## Tests

```sh
nxvim --test-plugin .
```

Covers the parser + layout, variable resolution, the VSCode loader, and the full
session and completion paths end-to-end.

[friendly-snippets]: https://github.com/rafamadriz/friendly-snippets
