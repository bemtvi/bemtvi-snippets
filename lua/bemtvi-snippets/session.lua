-- The tabstop SESSION — expand a snippet body and drive the cursor through its
-- tabstops, keeping mirrors in sync. This is where the core primitives compose:
--
--   btv.buf.set_text      (P1) splice the expansion over the trigger range, and update
--                             each mirror inline as the active tabstop changes
--   extmark gravity      (P2) anchor every tabstop occurrence as a *growing* range
--                             (right_gravity=false / end_right_gravity=true) so text
--                             typed into it is swallowed rather than landing outside
--   btv.buf.attach        (P3) react to each edit to re-sync mirrors; tear down on a
--                             wholesale reload (undo/redo/:e), where anchors are moot
--   btv.win.select_range  (P6) land on each tabstop: a placeholder with a default is
--                             SELECTED so the first keystroke replaces it, an empty
--                             tabstop degrades to a caret in Insert (P5's set_cursor)
--
-- One session at a time (like the native engine). No snippet syntax lives in the core:
-- the parser + this session are entirely plugin Lua over the generic seams.

local parser = require("bemtvi-snippets.parser")
local variables = require("bemtvi-snippets.variables")
local transform = require("bemtvi-snippets.transform")

local M = {}

local NS = btv.ns.create("bemtvi-snippets")

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

-- Split a (possibly multi-line) string into the line list btv.buf.set_text wants.
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

-- A mapper from a byte offset within `text` (inserted at 0-based row `sr`, byte column
-- `sc`) to its absolute (row, col). Built once per expansion over the text's newline
-- offsets, so each of the (two per occurrence) lookups is a binary search rather than a
-- fresh O(offset) substring scan.
local function pos_mapper(text, sr, sc)
  local nls, from = {}, 1
  while true do
    local nl = text:find("\n", from, true)
    if not nl then
      break
    end
    nls[#nls + 1] = nl - 1 -- 0-based offset of the newline byte
    from = nl + 1
  end
  return function(off)
    -- How many newlines lie strictly before `off` (the row delta).
    local lo, hi = 0, #nls
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if nls[mid] < off then
        lo = mid
      else
        hi = mid - 1
      end
    end
    if lo == 0 then
      return sr, sc + off
    end
    return sr + lo, off - (nls[lo] + 1)
  end
end

-- The buffer's indent unit for one leading TAB of a snippet body. VSCode collections
-- are tab-indented; a buffer with `'expandtab'` must get its own spaces instead of a
-- hard tab (`'shiftwidth'`, or `'tabstop'` when shiftwidth follows it via the 0
-- sentinel), the way every other indent in that buffer is produced.
local function indent_unit(buf)
  if not btv.bo[buf].expandtab then
    return "\t"
  end
  local width = btv.bo[buf].shiftwidth or 0
  if width == 0 then
    width = btv.bo[buf].tabstop or 8
  end
  if width <= 0 then
    width = 8
  end
  return string.rep(" ", width)
end

-- Fit a laid-out body to the buffer it lands in, remapping every tabstop occurrence's
-- byte span onto the new offsets. Two adjustments, in one pass:
--
--   * each line's own leading TABS become `unit` (the buffer's indent unit), so a
--     tab-indented collection body doesn't punch hard tabs into a spaces buffer;
--   * every line after the first is prefixed with `prefix` — the anchor line's leading
--     whitespace — so a multi-line body keeps its shape inside an indented block.
--
-- Offsets are 0-based bytes. Returns the fitted text and the remapped stops.
local function fit_to_buffer(text, stops, prefix, unit)
  if prefix == "" and unit == "\t" then
    return text, stops -- nothing to add, nothing to convert
  end

  -- One record per line: where it starts (in and out), how long its leading whitespace
  -- run is (in and out), and the run itself — everything `remap` needs.
  local out, lines, outlen, pos = {}, {}, 0, 1
  while true do
    local nl = text:find("\n", pos, true)
    local line = nl and text:sub(pos, nl - 1) or text:sub(pos)
    local lead = line:match("^[ \t]*")
    local body_lead = (lead:gsub("\t", unit))
    -- The first line continues the anchor line, so it takes no prefix — and neither
    -- does the empty tail a body-ending newline leaves behind: there is no content to
    -- indent there, only trailing whitespace to avoid.
    local line_prefix = (#lines == 0 or (nl == nil and line == "")) and "" or prefix
    lines[#lines + 1] = {
      in_start = pos - 1,
      out_start = outlen,
      lead = lead,
      lead_in = #lead,
      lead_out = #line_prefix + #body_lead,
      prefix_out = #line_prefix,
    }
    local rest = line:sub(#lead + 1)
    out[#out + 1] = line_prefix
    out[#out + 1] = body_lead
    out[#out + 1] = rest
    outlen = outlen + #line_prefix + #body_lead + #rest
    if not nl then
      break
    end
    out[#out + 1] = "\n"
    outlen, pos = outlen + 1, nl + 1
  end

  local function remap(off)
    local lo, hi = 1, #lines
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if lines[mid].in_start <= off then
        lo = mid
      else
        hi = mid - 1
      end
    end
    local l = lines[lo]
    local within = off - l.in_start
    if within >= l.lead_in then
      return l.out_start + l.lead_out + (within - l.lead_in)
    end
    -- Inside the line's own indentation: expand only the leading bytes before `off`.
    local w = l.out_start + l.prefix_out
    for k = 1, within do
      w = w + (l.lead:byte(k) == 9 and #unit or 1)
    end
    return w
  end

  local moved = {}
  for idx, occs in pairs(stops) do
    local no = { choices = occs.choices }
    for _, occ in ipairs(occs) do
      local n = { remap(occ[1]), remap(occ[2]) }
      n.transform = occ.transform
      no[#no + 1] = n
    end
    moved[idx] = no
  end
  return table.concat(out), moved
end

-- Every session extmark's current range, as `{ [id] = { row, col, end_row, end_col } }`.
-- ONE `btv.buf.extmarks` call: that accessor materializes and sorts the whole namespace
-- each time it is called, and a sync pass needs every occurrence — looking each mark up
-- on its own made a keystroke quadratic in the snippet's occurrence count.
local function mark_ranges(buf)
  local out = {}
  for _, m in ipairs(btv.buf.extmarks(buf, NS, 0, -1, { details = true })) do
    local d = m[4] or {}
    out[m[1]] = { m[2], m[3], d.end_row or m[2], d.end_col or m[3] }
  end
  return out
end

-- Re-sync every mirror of the ACTIVE tabstop to its primary occurrence's text. Reads a
-- consistent post-edit snapshot (it runs on its own tick, scheduled by `schedule_sync`),
-- and only rewrites a mirror whose text differs — so it converges: the mirror edits it
-- makes schedule one more pass that finds nothing to do.
--
-- The mirror edits are applied LAST-FIRST. `btv.buf.set_text` queues its edit to be
-- applied after this chunk, so a mirror rewritten earlier shifts every position to its
-- right; walking right-to-left keeps each remaining (chunk-start) coordinate valid. Left
-- to right, a snippet with two or more mirrors (`$1 = $1 + $1`) spliced the second one
-- at a stale column and corrupted the line.
local function do_sync()
  if not S then
    return
  end
  local stop = S.stops[S.order[S.pos]]
  if not stop or #stop.marks < 2 then
    return
  end
  local ranges = mark_ranges(S.buf)
  local pm = primary_mark(stop)
  local pr = ranges[pm.id]
  if not pr then
    return
  end
  local text = table.concat(btv.buf.text(S.buf, pr[1], pr[2], pr[3], pr[4]), "\n")

  local pending = {}
  for _, m in ipairs(stop.marks) do
    local r = m ~= pm and ranges[m.id]
    if r then
      -- A transformed occurrence renders the transform of the primary's text; a plain
      -- mirror copies it verbatim.
      local want = m.transform and transform.apply(text, m.transform) or text
      local cur = table.concat(btv.buf.text(S.buf, r[1], r[2], r[3], r[4]), "\n")
      if cur ~= want then
        pending[#pending + 1] = { r = r, want = want }
      end
    end
  end
  table.sort(pending, function(a, b)
    if a.r[1] ~= b.r[1] then
      return a.r[1] > b.r[1]
    end
    return a.r[2] > b.r[2]
  end)
  for _, edit in ipairs(pending) do
    local r = edit.r
    btv.buf.set_text(S.buf, r[1], r[2], r[3], r[4], split_lines(edit.want))
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
  btv.on_next_tick(function()
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
  if btv.buf.is_valid(S.buf) then
    btv.buf.clear_namespace(S.buf, NS, 0, -1)
  end
  S = nil
end

-- Land on a CHOICE stop (`${N|a,b,c|}`): open a NON-GRABBING dropdown of the
-- alternatives at the cursor (`btv.complete.choice`, the completion-popup widget — not
-- the modal `btv.ui.select`) so it reads as "pick one" while input keeps flowing. The
-- popup owns the pick: accepting a row splices it over the tabstop range natively, which
-- fires our `on_bytes` → the mirror sync. Nothing to do on this side but open it over
-- the primary occurrence's current range. Cancelling / typing keeps the current value.
local function open_choice(stop, range)
  btv.complete.choice(stop.choices, { range = range })
end

-- Land on tab-order position `pos`'s primary occurrence. A placeholder with a default
-- (`${1:name}`) is SELECTED so the first keystroke replaces it (P6 Select mode, via
-- `btv.win.select_range` with `on_escape = "insert"` so a bare <Esc> keeps the default
-- and stays editing); an empty tabstop (`$1` / `$0`) has a zero-width range, which
-- `select_range` degrades to caret + Insert — so one call covers both. Ends the session
-- when `pos` runs past the last stop, or when the stop's anchor is gone (its line was
-- deleted) — there is nothing left to land on.
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
  local r = mark_ranges(S.buf)[primary_mark(stop).id]
  if not r then
    M.finish()
    return
  end
  if stop.choices and #stop.choices > 0 then
    -- A choice stop offers a dropdown; the default value is already in the buffer.
    open_choice(stop, r)
  else
    -- 0-based rows/cols (select_range's convention); an empty span → caret + Insert.
    btv.win.select_range(0, r[1], r[2], r[3], r[4], { on_escape = "insert" })
  end
  -- $0 (the final stop) is terminal: landing on it and jumping again ends the session.
end

-- Jump to the next (`dir == 1`) / previous (`dir == -1`) tabstop. Returns true if a
-- session was live (so a keymap can decide whether to fall through). Ending on the
-- last stop is still a successful jump.
--
-- Leaving the snippet's buffer ends the session rather than jumping: the anchors are
-- the OTHER buffer's, while `select_range` / `btv.complete.choice` act on the current
-- window — so jumping from elsewhere would drive the caret to a foreign coordinate and
-- edit an unrelated buffer.
function M.jump(dir)
  if not S then
    return false
  end
  if btv.buf.current() ~= S.buf then
    M.finish()
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

  -- Fit the body to this buffer: continuation lines pick up the anchor line's leading
  -- whitespace (the text before the trigger on its line), and the body's own tab
  -- indentation becomes whatever this buffer indents with.
  local before = table.concat(btv.buf.text(buf, sr, 0, sr, sc), "")
  local indent = before:match("^[ \t]*") or ""
  text, spans = fit_to_buffer(text, spans, indent, indent_unit(buf))

  -- Splice the expansion over the trigger range (P1).
  btv.buf.set_text(buf, sr, sc, er, ec, split_lines(text))

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
  local abs = pos_mapper(text, sr, sc)
  btv.on_next_tick(function()
    if #order == 0 then
      -- No tabstops: park the caret at the end of the insertion and stop.
      local r, c = abs(#text)
      btv.win.set_cursor(0, r + 1, c)
      return
    end
    local stops = {}
    for idx, occs in pairs(spans) do
      local marks = {}
      for _, span in ipairs(occs) do
        local r, c = abs(span[1])
        local er2, ec2 = abs(span[2])
        local id = btv.buf.set_extmark(buf, NS, r, c, {
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
    S.detach = btv.buf.attach(buf, {
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
