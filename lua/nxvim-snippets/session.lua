-- The tabstop SESSION — expand a snippet body and drive the cursor through its
-- tabstops, keeping mirrors in sync. This is where the core primitives compose:
--
--   nx.buf.set_text      (P1) splice the expansion over the trigger range, and update
--                             each mirror inline as the active tabstop changes
--   extmark gravity      (P2) anchor every tabstop occurrence as a *growing* range
--                             (right_gravity=false / end_right_gravity=true) so text
--                             typed into it is swallowed rather than landing outside
--   nx.buf.attach        (P3) react to each edit to re-sync mirrors; tear down on a
--                             wholesale reload (undo/redo/:e), where anchors are moot
--   nx.win.select_range  (P6) land on each tabstop: a placeholder with a default is
--                             SELECTED so the first keystroke replaces it, an empty
--                             tabstop degrades to a caret in Insert (P5's set_cursor)
--
-- One session at a time (like the native engine). No snippet syntax lives in the core:
-- the parser + this session are entirely plugin Lua over the generic seams.

local parser = require("nxvim-snippets.parser")
local variables = require("nxvim-snippets.variables")
local transform = require("nxvim-snippets.transform")

local M = {}

local NS = nx.ns.create("nxvim-snippets")

-- The live session, or nil. Shape:
--   { buf, stops = { [index] = { marks = { { id, transform? }, ... } } },
--     order = {1,2,...,0}, pos, detach }
-- Each occurrence mark carries an optional `transform` spec: a plain mirror copies the
-- primary's text, a transformed occurrence (`${N/re/fmt/}`) renders the transform of it.
local S = nil

-- The primary (editable) occurrence of a stop: the first without a transform (a
-- transformed occurrence is derived, never the caret target). Falls back to the first.
local function primary_mark(stop)
  for _, m in ipairs(stop.marks) do
    if not m.transform then
      return m
    end
  end
  return stop.marks[1]
end

-- Split a (possibly multi-line) string into the line list nx.buf.set_text wants.
local function split_lines(text)
  local out, start = {}, 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      out[#out + 1] = text:sub(start)
      break
    end
    out[#out + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  return out
end

-- Absolute (row, col) of byte offset `off` within `text` inserted at (sr, sc). 0-based
-- row; col is a byte offset within its line. Later lines of the insertion start at
-- col 0 (no re-indent in this scaffold).
local function abs_pos(text, off, sr, sc)
  local before = text:sub(1, off)
  local nl, last = 0, 0
  for i = 1, #before do
    if before:byte(i) == 10 then
      nl, last = nl + 1, i
    end
  end
  if nl == 0 then
    return sr, sc + off
  end
  return sr + nl, off - last
end

-- Re-indent a multi-line expansion so every line after the first is prefixed with
-- `indent` (the anchor line's leading whitespace), and remap each tabstop occurrence's
-- byte spans onto the new offsets. A single-line body — or no indent — is returned
-- untouched. Mirrors the native engine's continuation-line indenting.
local function reindent(text, stops, indent)
  if indent == "" or not text:find("\n", 1, true) then
    return text, stops
  end
  -- map[off] = the output byte offset of input byte offset `off` (0-based).
  local map, out, outlen, prev_nl = {}, {}, 0, false
  for i = 1, #text do
    if prev_nl then
      out[#out + 1] = indent
      outlen = outlen + #indent
    end
    map[i - 1] = outlen
    out[#out + 1] = text:sub(i, i)
    outlen = outlen + 1
    prev_nl = text:byte(i) == 10
  end
  map[#text] = outlen
  local newstops = {}
  for idx, occs in pairs(stops) do
    local no = { choices = occs.choices }
    for _, occ in ipairs(occs) do
      local n = { map[occ[1]], map[occ[2]] }
      n.transform = occ.transform
      no[#no + 1] = n
    end
    newstops[idx] = no
  end
  return table.concat(out), newstops
end

-- The current (row, col, end_row, end_col) of extmark `id`, or nil if it's gone.
local function mark_range(buf, id)
  local ms = nx.buf.extmarks(buf, NS, 0, -1, { details = true })
  for _, m in ipairs(ms) do
    if m[1] == id then
      local d = m[4] or {}
      return m[2], m[3], d.end_row or m[2], d.end_col or m[3]
    end
  end
  return nil
end

-- The text currently spanned by extmark `id` (joined with `\n`), or nil.
local function mark_text(buf, id)
  local r, c, er, ec = mark_range(buf, id)
  if not r then
    return nil
  end
  return table.concat(nx.buf.text(buf, r, c, er, ec), "\n")
end

-- Re-sync every mirror of the ACTIVE tabstop to its primary occurrence's text. Called
-- after each edit. Diff-guarded, so it converges: once mirrors equal the primary the
-- next edit finds nothing to do (no infinite re-entry through on_bytes).
-- Re-sync every mirror of the ACTIVE tabstop to its primary occurrence's text. Reads
-- a consistent post-edit snapshot (it runs on its own tick, scheduled by
-- `schedule_sync`), and only rewrites a mirror whose text differs — so it converges:
-- the mirror edits it makes schedule one more pass that finds nothing to do.
local function do_sync()
  if not S then
    return
  end
  local stop = S.stops[S.order[S.pos]]
  if not stop or #stop.marks < 2 then
    return
  end
  local pm = primary_mark(stop)
  local text = mark_text(S.buf, pm.id)
  if not text then
    return
  end
  for _, m in ipairs(stop.marks) do
    if m ~= pm then
      local r, c, er, ec = mark_range(S.buf, m.id)
      if r then
        -- A transformed occurrence renders the transform of the primary's text; a plain
        -- mirror copies it verbatim.
        local want = m.transform and transform.apply(text, m.transform) or text
        local cur = table.concat(nx.buf.text(S.buf, r, c, er, ec), "\n")
        if cur ~= want then
          nx.buf.set_text(S.buf, r, c, er, ec, split_lines(want))
        end
      end
    end
  end
end

-- Debounce a mirror sync onto the next tick: rapid keystrokes coalesce into one pass
-- that reads the FINAL state, and the sync's own mirror edits (which re-fire on_bytes)
-- schedule at most one follow-up pass, which the diff-guard makes a no-op. Reading on a
-- separate tick sidesteps the extmark mirror's "positions as of chunk start" lag.
local function schedule_sync()
  if not S or S.sync_pending then
    return
  end
  S.sync_pending = true
  nx.on_next_tick(function()
    if not S then
      return
    end
    S.sync_pending = false
    do_sync()
  end)
end

-- Whether a session is live.
function M.active()
  return S ~= nil
end

-- Tear the session down: detach the change channel and drop the tabstop extmarks.
function M.finish()
  if not S then
    return
  end
  if S.detach then
    S.detach()
  end
  nx.buf.clear_namespace(S.buf, NS, 0, -1)
  S = nil
end

-- Land on tab-order position `pos`'s primary occurrence. A placeholder with a default
-- (`${1:name}`) is SELECTED so the first keystroke replaces it (P6 Select mode, via
-- `nx.win.select_range` with `on_escape = "insert"` so a bare <Esc> keeps the default
-- and stays editing); an empty tabstop (`$1` / `$0`) has a zero-width range, which
-- `select_range` degrades to caret + Insert — so one call covers both. Ends the session
-- when `pos` runs past the last stop.
-- Land on a CHOICE stop (`${N|a,b,c|}`): open a NON-GRABBING dropdown of the
-- alternatives at the cursor (`nx.complete.choice`, the completion-popup widget — not
-- the modal `nx.ui.select`) so it reads as "pick one" while input keeps flowing. The
-- popup owns the pick: accepting a row splices it over the tabstop range natively, which
-- fires our `on_bytes` → the mirror sync. Nothing to do on this side but open it over
-- the primary occurrence's current range. Cancelling / typing keeps the current value.
local function open_choice(stop)
  local r, c, er, ec = mark_range(S.buf, primary_mark(stop).id)
  if r then
    nx.complete.choice(stop.choices, { range = { r, c, er, ec } })
  end
end

local function goto_pos(pos)
  if pos > #S.order then
    M.finish()
    return
  end
  -- Jumping to the previous stop while already on the first one stays put — clamp
  -- rather than indexing `S.order[0]` (nil, since Lua lists are 1-based), which would
  -- crash `primary_mark(nil)`. Matches vim's snippet jump (prev at $1 is a no-op).
  if pos < 1 then
    pos = 1
  end
  S.pos = pos
  local stop = S.stops[S.order[pos]]
  local r, c, er, ec = mark_range(S.buf, primary_mark(stop).id)
  if not r then
    return
  end
  if stop.choices and #stop.choices > 0 then
    -- A choice stop offers a dropdown; the default value is already in the buffer.
    open_choice(stop)
  else
    -- 0-based rows/cols (select_range's convention); an empty span → caret + Insert.
    nx.win.select_range(0, r, c, er, ec, { on_escape = "insert" })
  end
  -- $0 (the final stop) is terminal: landing on it and jumping again ends the session.
end

-- Jump to the next (`dir == 1`) / previous (`dir == -1`) tabstop. Returns true if a
-- session was live (so a keymap can decide whether to fall through). Ending on the
-- last stop is still a successful jump.
function M.jump(dir)
  if not S then
    return false
  end
  goto_pos(S.pos + dir)
  return true
end

-- expand(buf, sr, sc, er, ec, body[, ctx]) — replace the range (sr,sc)..(er,ec) with
-- `body` expanded (variables resolved via `ctx`), anchor its tabstops, and jump to the
-- first. `body` may be a string (parsed) or a pre-parsed AST. Any prior session is
-- ended first. Raises (fail loud) on a malformed / unsupported body.
function M.expand(buf, sr, sc, er, ec, body, ctx)
  M.finish()
  local ast = type(body) == "string" and parser.parse(body) or body
  local text, spans = parser.layout(ast, function(name)
    return variables.resolve(name, ctx)
  end)

  -- Re-indent continuation lines to the anchor line's leading whitespace, so a
  -- multi-line body expanded inside an indented block keeps its shape (the trigger's
  -- own indent is the text before it on the line).
  local before = table.concat(nx.buf.text(buf, sr, 0, sr, sc), "")
  local indent = before:match("^[ \t]*") or ""
  text, spans = reindent(text, spans, indent)

  -- Splice the expansion over the trigger range (P1).
  nx.buf.set_text(buf, sr, sc, er, ec, split_lines(text))

  -- Tab order: real stops ascending, then $0 last (if present).
  local order = {}
  for idx in pairs(spans) do
    if idx ~= 0 then
      order[#order + 1] = idx
    end
  end
  table.sort(order)
  if spans[0] then
    order[#order + 1] = 0
  end

  -- The edit is queued; on the next tick the text is in the buffer, so anchor the
  -- growing tabstop extmarks (P2) at the now-materialized positions, jump to the first
  -- (P5), and start listening for edits to keep mirrors in sync (P3).
  nx.on_next_tick(function()
    if #order == 0 then
      -- No tabstops: park the caret at the end of the insertion and stop.
      local r, c = abs_pos(text, #text, sr, sc)
      nx.win.set_cursor(0, r + 1, c)
      return
    end
    local stops = {}
    for idx, occs in pairs(spans) do
      local marks = {}
      for _, span in ipairs(occs) do
        local r, c = abs_pos(text, span[1], sr, sc)
        local er2, ec2 = abs_pos(text, span[2], sr, sc)
        local id = nx.buf.set_extmark(buf, NS, r, c, {
          end_row = er2,
          end_col = ec2,
          right_gravity = false,
          end_right_gravity = true,
          hl_group = "SnippetTabstop",
        })
        marks[#marks + 1] = { id = id, transform = span.transform }
      end
      stops[idx] = { marks = marks, choices = occs.choices }
    end
    S = { buf = buf, stops = stops, order = order, pos = 0, detach = nil }
    S.detach = nx.buf.attach(buf, {
      on_bytes = function()
        schedule_sync()
      end,
      on_reload = function()
        M.finish()
      end,
    })
    goto_pos(1)
  end)
end

return M
