-- VSCode snippet VARIABLE resolution.
--
-- The snippet body references variables like `$TM_FILENAME` or `$CURRENT_YEAR`; the
-- parser leaves them as `var` nodes and the session resolves them here at expand time
-- (they depend on runtime context — the file, the selection, the clock). Every read is
-- through the public `btv.*` surface (buffer name, buffer options, registers, `os.date`),
-- so this stays a pure-Lua plugin. An unknown variable resolves to `nil`, so the parser
-- falls back to the variable's `${VAR:default}` text (or empty) — matching VSCode.
--
-- Each variable is a FUNCTION in one of the tables below rather than an entry in a
-- table built per call: resolving `$TM_FILENAME` must not read the clock, the registers
-- and the cursor as well. Only the variable actually asked for does any work.

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

-- The buffer a resolution reads from: the caller's override, else the current one.
-- Resolved to a real number so the `btv.bo` / `btv.buf` reads below never depend on the
-- "0 means current" alias.
local function target_buf(ctx)
  local buf = ctx.buf
  if buf == nil or buf == 0 then
    return btv.buf.current()
  end
  return buf
end

-- The project root a path is reported relative to: the workspace root when this session
-- has one, else the editor's working directory.
local function root_dir()
  local ws = btv.workspace and btv.workspace.dir and btv.workspace.dir()
  if ws and ws ~= "" then
    return ws
  end
  return vim.fn.getcwd() or ""
end

-- `path` with `root`'s prefix stripped, when it is under it; the path unchanged
-- otherwise (VSCode reports an out-of-workspace file by its absolute path).
local function relative_to(path, root)
  if root ~= "" and path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

-- The word (`[A-Za-z0-9_]` run) the caret sits in, or "" when it sits on none. In
-- Insert mode the caret rests one byte PAST the word being typed, so it clamps to the
-- last byte of the line — which is that word, the one VSCode means.
local function word_under_cursor()
  local line = btv.current_line() or ""
  local col = (btv.cursor.get()[2] or 0) + 1 -- 1-based byte index
  if col > #line then
    col = #line
  end
  if col < 1 or not line:sub(col, col):match("[%w_]") then
    return ""
  end
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_]") do
    s = s - 1
  end
  while e < #line and line:sub(e + 1, e + 1):match("[%w_]") do
    e = e + 1
  end
  return line:sub(s, e)
end

-- The buffer's comment delimiters, from the canonical `'commentstring'` (a `%s`
-- template) rather than a filetype guess: `left, right`, each already trimmed. A line
-- comment has an empty `right` (`-- %s`); a wrapping template (`/* %s */`) has both.
-- Returns nil when the buffer has no commentstring at all.
local function comment_parts(buf)
  local cs = btv.bo[buf].commentstring
  if type(cs) ~= "string" or cs == "" then
    return nil
  end
  local left, right = cs:match("^(.-)%%s(.*)$")
  if not left then
    return nil
  end
  return (left:gsub("%s+$", "")), (right:gsub("^%s+", ""))
end

-- ----- the variable families ------------------------------------------------
-- Each entry is `function(ctx) -> string | nil`. A nil return means "unknown", which
-- the parser turns into the variable's own `${VAR:default}`.

-- Date / time (VSCode's CURRENT_* family). `os.date("*t")` / `os.time()` are read
-- inside the entry, so a snippet with no date variable never calls them.
local DATE = {
  CURRENT_YEAR = function()
    return tostring(os.date("*t").year)
  end,
  CURRENT_YEAR_SHORT = function()
    return tostring(os.date("*t").year):sub(-2)
  end,
  CURRENT_MONTH = function()
    return pad2(os.date("*t").month)
  end,
  CURRENT_DATE = function()
    return pad2(os.date("*t").day)
  end,
  CURRENT_HOUR = function()
    return pad2(os.date("*t").hour)
  end,
  CURRENT_MINUTE = function()
    return pad2(os.date("*t").min)
  end,
  CURRENT_SECOND = function()
    return pad2(os.date("*t").sec)
  end,
  CURRENT_DAY_NAME = function()
    return os.date("%A")
  end,
  CURRENT_DAY_NAME_SHORT = function()
    return os.date("%a")
  end,
  CURRENT_MONTH_NAME = function()
    return os.date("%B")
  end,
  CURRENT_MONTH_NAME_SHORT = function()
    return os.date("%b")
  end,
  CURRENT_SECONDS_UNIX = function()
    return tostring(os.time())
  end,
  -- VSCode's ISO-8601 form (`+02:00`), from `os.date`'s `+0200`.
  CURRENT_TIMEZONE_OFFSET = function()
    local z = os.date("%z")
    local sign, hh, mm = tostring(z):match("^([+-])(%d%d)(%d%d)$")
    if not sign then
      return nil
    end
    return sign .. hh .. ":" .. mm
  end,
}

-- The current file / cursor family.
local FILE = {
  TM_FILENAME = function(ctx)
    local _dir, file = path_parts(btv.buf.name(target_buf(ctx)))
    return file
  end,
  TM_FILENAME_BASE = function(ctx)
    local _dir, _file, base = path_parts(btv.buf.name(target_buf(ctx)))
    return base
  end,
  TM_DIRECTORY = function(ctx)
    local dir = path_parts(btv.buf.name(target_buf(ctx)))
    return dir
  end,
  TM_FILEPATH = function(ctx)
    return btv.buf.name(target_buf(ctx)) or ""
  end,
  -- The file path relative to the workspace root / cwd — the whole point of the
  -- variable (VSCode's absolute form is TM_FILEPATH).
  RELATIVE_FILEPATH = function(ctx)
    return relative_to(btv.buf.name(target_buf(ctx)) or "", root_dir())
  end,
  TM_LINE_INDEX = function(ctx)
    return tostring((ctx.line or btv.cursor.get()[1] or 1) - 1)
  end,
  TM_LINE_NUMBER = function(ctx)
    return tostring(ctx.line or btv.cursor.get()[1] or 1)
  end,
  TM_CURRENT_LINE = function(ctx)
    return ctx.current_line or btv.current_line() or ""
  end,
  TM_CURRENT_WORD = function(ctx)
    return ctx.word or word_under_cursor()
  end,
  TM_SELECTED_TEXT = function(ctx)
    return ctx.selection or btv.reg.get('"') or ""
  end,
}

-- Workspace / clipboard / comment / misc.
local MISC = {
  CLIPBOARD = function()
    return btv.reg.get("+") or btv.reg.get('"') or ""
  end,
  WORKSPACE_FOLDER = function()
    return root_dir()
  end,
  WORKSPACE_NAME = function()
    local root = root_dir()
    return root:match("([^/]+)/?$") or root
  end,
  LINE_COMMENT = function(ctx)
    local left, right = comment_parts(target_buf(ctx))
    -- Only a template with nothing trailing is a LINE comment; a wrapping `/* %s */`
    -- has no line form, so this stays unknown rather than emitting a stray `/*`.
    if left and right == "" and left ~= "" then
      return left
    end
    return nil
  end,
  BLOCK_COMMENT_START = function(ctx)
    local left, right = comment_parts(target_buf(ctx))
    if left and right ~= "" then
      return left
    end
    return nil
  end,
  BLOCK_COMMENT_END = function(ctx)
    local _left, right = comment_parts(target_buf(ctx))
    if right and right ~= "" then
      return right
    end
    return nil
  end,
  UUID = function()
    return btv.uuid()
  end,
  -- Genuinely random, per VSCode: six decimal digits. (Deriving these from the clock
  -- made every `$RANDOM` in one expansion identical, and repeatable within a second.)
  RANDOM = function()
    return string.format("%06d", math.random(0, 999999))
  end,
  RANDOM_HEX = function()
    return string.format("%06x", math.random(0, 0xffffff))
  end,
}

-- resolve(name[, ctx]) -> string | nil
--   `ctx` (optional) carries `{ buf, line, current_line, word, selection }` overrides
--   the caller can supply; anything absent is read live. Returns nil for an unknown
--   variable so the parser uses its default.
function M.resolve(name, ctx)
  local entry = DATE[name] or FILE[name] or MISC[name]
  if entry == nil then
    return nil
  end
  return entry(ctx or {})
end

return M
