<!-- DO NOT EDIT doc/nxvim-snippets.txt BY HAND. It is generated from this file by
panvimdoc — run `scripts/gen-vimdoc.sh` after editing. -->

A snippet engine for nxvim, built entirely on the native `nx.*` plugin API — no snippet syntax lives
in the editor core. It loads VSCode-format snippet collections (e.g. friendly-snippets), offers them
in the completion menu, and expands the chosen one into a live tabstop session with mirrors,
choices, and transforms.

It is the nxvim answer to LuaSnip / vsnip: the same LSP snippet-body grammar and the same
VSCode-collection loading, re-expressed in nxvim's idiom and standing entirely on generic core
primitives (see How it works).

<!-- Passed through verbatim so `:help nxvim-snippets` lands on this page
     (panvimdoc derives per-section tags but no bare project tag). -->
```vimdoc
                                                               *nxvim-snippets*
```

# Install

Put the repo on your `runtimepath` — with `nx.plugins`, or any plugin manager.
`plugin/nxvim-snippets.lua` auto-sources on load and registers the completion source and the jump
keymaps with defaults, so the engine works before you call anything:

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

Run `:PluginSync` to clone it. Listing friendly-snippets as a dependency is all that is needed to
get a large snippet library — it lands on the runtimepath, and discovery finds it (see Collections).

# Quick start

```lua
local snip = require("nxvim-snippets")
snip.setup({})

-- Enable the completion engine however you like — the snippet
-- source joins it automatically (registering a source activates
-- it; there is nothing to route):
nx.complete.setup({ sources = { { "buffer" } } })

-- Add snippets inline …
snip.add("lua", {
  {
    trigger = "lf",
    body = "local function ${1:name}(${2:args})\n\t$0\nend",
  },
})

-- … or point discovery at a VSCode collection that is not on
-- the runtimepath:
snip.add_collection("/path/to/snippets-collection")
```

Type a trigger, accept the completion row with `<C-y>`, and you land in the snippet on the first
tabstop. `<C-j>` / `<C-k>` jump to the next / previous tabstop (configurable — see `setup()`).

# Collections

The easiest way to get a big snippet library is to add a VSCode-format collection such as
friendly-snippets <https://github.com/rafamadriz/friendly-snippets> to your runtimepath — as a
plugin dependency — and do nothing else. `setup{}` discovers any VSCode collection on the
runtimepath and offers its snippets in completion automatically.

Loading is LAZY and CACHED, so a 9,000-snippet collection costs almost nothing up front:

- `setup{}` reads only each collection's small `package.json` manifest,
  to learn which files feed which filetype.
- A language's actual snippet files are read the first time a completion
  needs that filetype, then cached — every later keystroke is served
  from memory with no disk I/O.
- Languages you never edit are never read.

For a collection that is NOT on the runtimepath, register it explicitly with
`snip.add_collection("/path/to/collection")` (a dir, or a list of dirs) — it joins the same lazy
discovery. Set `setup{ discover_runtimepath = false }` to turn the runtimepath sweep off;
explicitly-added collections are still discovered either way.

A collection is the standard VSCode layout: a `package.json` whose `contributes.snippets` lists
`{ language, path }` entries, plus per-language JSON files mapping a name to
`{ prefix, body, description }`. Both `prefix` and `body` may be a string or a list of strings; a
list `prefix` fans out into one snippet per trigger.

Each VSCode language id becomes the nxvim filetype of the same name, except where the two differ —
`shellscript` is nxvim's `bash`, `csharp` is `c_sharp`, `typescriptreact` is `tsx`, and
`javascriptreact` folds into `javascript` (nxvim has no separate JSX filetype). A collection
reachable twice — on the runtimepath AND passed to `add_collection` — is swept once, not offered
twice.

Nothing in a collection is allowed to break the sweep: a `package.json` that is not a snippet
collection, is unreadable, or is not valid JSON is skipped silently, and a snippet file that is
unreadable or malformed is reported with `nx.notify` and skipped — so one bad file does not sink a
whole language, and one bad manifest does not sink discovery.

# Body grammar

The LSP / VSCode snippet syntax:

```
$1  ${1}              a tabstop ($0 is the final one)
${1:default}          a placeholder (may nest)
${1|a,b,c|}           a choice — landing on it opens a dropdown
a repeated $1         a mirror — every occurrence renders index 1's text
$TM_FILENAME          a variable (resolved at expand)
${VAR:fallback}       a variable with a default
${1/regex/format/g}   a transform (live for a tabstop, static
                      for a variable)
\$  \}  \\            escapes (and \, \| inside a choice list)
```

A malformed or unsupported body raises — it is never silently mis-expanded.

## Transforms

Transforms run the regex on nxvim's native engine (`nx.regex`, the `pcre` dialect) and build the
replacement from the `format` mini-language:

```
$1  ${1}         a group reference ($0 is the whole match)
${1:/upcase}     a case op: /upcase /downcase /capitalize
                 /pascalcase /camelcase
${1:+if}         emit `if` only when the group participated
${1:-else}       emit the group, or `else` when it did not
${1:?if:else}    emit `if` when the group participated, `else` otherwise
```

The trailing options accept `g` (replace every match, not just the first) and `i` (case-insensitive).
A tabstop transform (`${1/…/…/}`) recomputes LIVE as you type the source tabstop; a variable
transform is applied once, at expand.

## Variables

Resolved at expand time, from the buffer, its options, and the clock:

```
CURRENT_YEAR  CURRENT_YEAR_SHORT  CURRENT_MONTH  CURRENT_DATE
CURRENT_HOUR  CURRENT_MINUTE  CURRENT_SECOND  CURRENT_SECONDS_UNIX
CURRENT_DAY_NAME  CURRENT_DAY_NAME_SHORT
CURRENT_MONTH_NAME  CURRENT_MONTH_NAME_SHORT
CURRENT_TIMEZONE_OFFSET
TM_FILENAME  TM_FILENAME_BASE  TM_DIRECTORY  TM_FILEPATH
RELATIVE_FILEPATH
TM_LINE_NUMBER  TM_LINE_INDEX  TM_CURRENT_LINE  TM_CURRENT_WORD
TM_SELECTED_TEXT  CLIPBOARD  WORKSPACE_NAME  WORKSPACE_FOLDER
LINE_COMMENT  BLOCK_COMMENT_START  BLOCK_COMMENT_END
UUID  RANDOM  RANDOM_HEX
```

A few are worth spelling out:

- `WORKSPACE_FOLDER` is the workspace root when the session
  has one (`nx.workspace.dir()`), else the editor's working
  directory; `WORKSPACE_NAME` is that directory's base name.
- `RELATIVE_FILEPATH` is the file relative to that same root
  (`TM_FILEPATH` is the absolute one). A file outside the root
  keeps its absolute path, as in VSCode.
- `TM_CURRENT_WORD` is the identifier the caret sits in — in
  Insert mode, the word being typed.
- `LINE_COMMENT` / `BLOCK_COMMENT_START` / `BLOCK_COMMENT_END`
  come from the buffer's `'commentstring'`, so they follow
  whatever the filetype (or your own `:setlocal`) says. A line
  template (`-- %s`) defines only `LINE_COMMENT`; a wrapping
  one (`/* %s */`) defines only the block pair.
- `RANDOM` (six digits) and `RANDOM_HEX` (six hex digits) are
  genuinely random per occurrence.

An unknown variable falls back to its `${VAR:default}` (or empty), matching VSCode.

# The session

Expanding starts a tabstop session — one at a time, like the native engine.

- Every occurrence of a tabstop is anchored as a GROWING extmark range,
  highlighted with the `SnippetTabstop` group, so text you type into it
  is swallowed rather than pushed outside.
- A placeholder with a default (`${1:name}`) is SELECTED when you land
  on it, so the first keystroke replaces it. A bare `<Esc>` keeps the
  default and stays in Insert. An empty tabstop (`$1` / `$0`) just gets
  the caret.
- A choice stop (`${1|a,b,c|}`) opens a non-grabbing dropdown of the
  alternatives at the cursor — `<C-n>` / `<C-p>` to move, `<CR>` to
  pick. Cancelling or typing keeps the current value.
- Mirrors re-sync after each edit, on the next tick, so rapid keystrokes
  coalesce into one pass. A transformed occurrence renders the transform
  of the primary's text instead of a verbatim copy.
- A body is fitted to the buffer it lands in: every line after the first
  is prefixed with the anchor line's leading whitespace, and the body's
  own leading tabs (every VSCode collection is tab-indented) become the
  buffer's indent unit — `'shiftwidth'` spaces under `'expandtab'`.
- Jumping past the last stop ends the session, as does `snip.abort()`,
  leaving the snippet's buffer, or a wholesale buffer reload (undo/redo,
  `:e`), where the anchors are moot.

# Completion

The engine registers a `nx.complete` source named `nxvim-snippets`. Registering ACTIVATES it — it
joins the live `nx.complete` engine on its own, even if you called `nx.complete.setup{}` before
loading this plugin, so you never list it in `sources`.

Its defaults: `priority = 5` (a small bias that breaks near-ties against buffer words without burying
a clearly better match), `min_chars = 2` (short triggers like `lf` open the menu), and `debounce = 0`
(snippets are in-memory data, so there is nothing to wait for).

List it in `sources` only to override those:

```lua
nx.complete.setup({
  sources = {
    { "buffer" },
    { "nxvim-snippets", min_chars = 3, priority = 20 },
  },
})
```

Use `nx.complete.setup{ exclusive = true }` if you would rather opt out of auto-join and control the
source list yourself.

A snippet row reads `Snippet` in the right-aligned kind column, and selecting it previews the
expansion in the docs float — the body fenced as a code block tagged with the buffer's filetype, led
by the snippet's `description` when it has one. The preview is built for the row you actually land
on (the source's `resolve` callback), not for every candidate on every keystroke, so a large
collection costs nothing extra while you type.

# API

```lua
local snip = require("nxvim-snippets")
```

`snip.setup(opts)` — (re)configure: register the completion source (it
auto-joins `nx.complete`) and install the jump keymaps. Calling it again is a full
reconfigure — discovery re-runs from scratch (replacing what it had read, never
duplicating it), while snippets you registered with `snip.add` are kept.

```lua
require("nxvim-snippets").setup({
  -- The jump keys, mapped in BOTH Insert and Select mode (a selected
  -- placeholder must be jumpable too). `false` skips installing one, so
  -- you can map `snip.jump_next` / `snip.jump_prev` yourself.
  jump_next = "<C-j>",
  jump_prev = "<C-k>",

  -- The source's own prefix gate: how many typed chars before
  -- snippets show.
  min_chars = 2,

  -- Auto-discover VSCode collections on the runtimepath and
  -- lazy-load them per filetype. `false` turns the sweep off;
  -- collections added with `add_collection` are still discovered.
  discover_runtimepath = true,
})
```

The rest of the surface:

- `snip.add(ft, list)` — register `{ trigger, body, description? }`
  entries for a filetype. The `"all"` filetype is offered in every
  buffer (VSCode's global scope). Fails loud on a bad entry shape.
- `snip.add_collection(dirs)` — add a VSCode collection root (a dir, or
  a list of them) to the lazy auto-discovery, for a collection that is
  not on the runtimepath. Safe to call at any time: it invalidates the
  discovery caches, so filetypes already loaded pick the new root up on
  their next completion.
- `snip.expand(body)` — expand a body at the cursor right now, starting
  a session. The manual counterpart of accepting a completion row.
- `snip.jump_next()` / `snip.jump_prev()` — jump tabstops. Each returns
  whether a session was live, so a custom keymap can fall through when
  it was not.
- `snip.abort()` — end the active session.
- `snip.active()` — whether a session is live.
- `snip.get(ft)` — the snippets registered for a filetype, plus the
  global `"all"` bucket. The list is memoized and shared — read it,
  don't mutate it.
- `snip.parse(body)` — parse a body into its AST without expanding (for
  tests and tooling). Raises on bad input.

# How it works

nxvim's core stays bare: it grows generic text-editing seams, and features like this snippet engine
are plain Lua on top. These primitives make it possible — none of them mentions "snippet":

```
nx.buf.set_text        splice the expansion over the trigger
                       word; update mirrors inline
extmark gravity        right_gravity=false / end_right_gravity=true
                       anchor each tabstop as a growing range, so
                       typed text is swallowed, not pushed outside
nx.buf.attach on_bytes react to each edit to keep mirrors in sync;
                       tear down on a reload
nx.complete on_accept  the completion row that expands instead of
                       inserting literal text
nx.win.select_range    land on a tabstop — a placeholder is
                       SELECTED, an empty stop degrades to a caret
```

See `docs/specs/2026-07-21-snippet-engine-primitives.md` in the nxvim repo for the design.

The module map:

```
parser.lua     the LSP/VSCode body grammar → AST → text + tabstop spans
variables.lua  VSCode variable resolution ($TM_FILENAME, $CURRENT_YEAR, …)
transform.lua  the ${N/regex/format/opts} format mini-language
session.lua    the tabstop session (expand / jump / mirror sync)
source.lua     the nx.complete.source integration (on_accept)
vscode.lua     discover VSCode collections + lazily load them per filetype
```

# Coverage

Against the full friendly-snippets collection (9,213 snippets across 128 filetypes): all 9,213
parse, and 9,211 (99.98%) lay out and expand. The 2 that do not use a regex lookbehind
(`(?<=…)`) in a transform, which nxvim's regex engine (the Rust `regex` crate) cannot compile — those
fail LOUD with a clear error rather than mis-expanding.

# Trying it locally

This repo ships a runnable demo — a few Lua snippets plus a scratch buffer:

```sh
NXVIM_CONFIG=examples nxvim examples/sample.lua
```

(run from a checkout of this repo). In insert mode type `lf`, `req`, `log`, or `today`, accept the
row with `<C-y>`, and jump with `<C-j>` / `<C-k>`.

# Tests

```sh
nxvim --test-plugin .
```

Covers the parser and layout, transforms, variable resolution, the VSCode loader and its lazy
per-filetype caching, and the full session and completion paths end-to-end.
