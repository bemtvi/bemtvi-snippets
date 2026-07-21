-- VSCode snippet VARIABLE resolution.
--
-- The snippet body references variables like `$TM_FILENAME` or `$CURRENT_YEAR`; the
-- parser leaves them as `var` nodes and the session resolves them here at expand time
-- (they depend on runtime context — the file, the selection, the clock). Every read is
-- through the public `nx.*` surface (buffer name, registers, `os.date`), so this stays
-- a pure-Lua plugin. An unknown variable resolves to `nil`, so the parser falls back to
-- the variable's `${VAR:default}` text (or empty) — matching VSCode.

local M = {}

-- Two-digit zero-padded string (for month / day / clock fields).
local function pad2(n)
  return string.format("%02d", n)
end

-- Split a path into (dir, base, name-without-ext, ext).
local function path_parts(path)
  path = path or ""
  local dir, file = path:match("^(.*)/([^/]*)$")
  if not file then
    dir, file = "", path
  end
  local base_no_ext, ext = file:match("^(.*)%.([^.]*)$")
  if not base_no_ext then
    base_no_ext, ext = file, ""
  end
  return dir, file, base_no_ext, ext
end

-- resolve(name[, ctx]) -> string | nil
--   `ctx` (optional) carries `{ buf, selection, line, word }` overrides the caller can
--   supply; anything absent is read live. Returns nil for an unknown variable so the
--   parser uses its default.
function M.resolve(name, ctx)
  ctx = ctx or {}
  local now = os.date("*t")

  -- Date / time (VSCode's CURRENT_* family).
  local dates = {
    CURRENT_YEAR = tostring(now.year),
    CURRENT_YEAR_SHORT = tostring(now.year):sub(-2),
    CURRENT_MONTH = pad2(now.month),
    CURRENT_DATE = pad2(now.day),
    CURRENT_HOUR = pad2(now.hour),
    CURRENT_MINUTE = pad2(now.min),
    CURRENT_SECOND = pad2(now.sec),
    CURRENT_DAY_NAME = os.date("%A"),
    CURRENT_DAY_NAME_SHORT = os.date("%a"),
    CURRENT_MONTH_NAME = os.date("%B"),
    CURRENT_MONTH_NAME_SHORT = os.date("%b"),
    CURRENT_SECONDS_UNIX = tostring(os.time()),
  }
  if dates[name] ~= nil then
    return dates[name]
  end

  -- File path family (the current buffer's name).
  if name:sub(1, 3) == "TM_" or name == "RELATIVE_FILEPATH" then
    local path = nx.buf.name(ctx.buf or 0) or ""
    local dir, file, base_no_ext, _ext = path_parts(path)
    local file_vars = {
      TM_FILENAME = file,
      TM_FILENAME_BASE = base_no_ext,
      TM_DIRECTORY = dir,
      TM_FILEPATH = path,
      RELATIVE_FILEPATH = path,
      TM_LINE_INDEX = tostring((ctx.line or nx.cursor.get()[1] or 1) - 1),
      TM_LINE_NUMBER = tostring(ctx.line or nx.cursor.get()[1] or 1),
      TM_CURRENT_LINE = ctx.current_line or nx.current_line() or "",
      TM_CURRENT_WORD = ctx.word or "",
      TM_SELECTED_TEXT = ctx.selection or nx.reg.get('"') or "",
    }
    if file_vars[name] ~= nil then
      return file_vars[name]
    end
  end

  -- Clipboard / workspace / misc.
  if name == "CLIPBOARD" then
    return nx.reg.get("+") or nx.reg.get('"') or ""
  elseif name == "WORKSPACE_NAME" or name == "WORKSPACE_FOLDER" then
    local _dir, file = path_parts(nx.buf.name(ctx.buf or 0) or "")
    return file -- best-effort; nxvim has no project root concept here
  elseif name == "UUID" then
    return nx.uuid()
  elseif name == "RANDOM" then
    return string.format("%06d", math.floor((os.time() * 131071) % 1000000))
  elseif name == "RANDOM_HEX" then
    return string.format("%06x", os.time() % 0xffffff)
  end

  return nil -- unknown ⇒ the parser falls back to the variable's default
end

return M
