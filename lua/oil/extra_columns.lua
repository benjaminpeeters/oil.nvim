-- Fork additions to oil's columns, for use in right_columns. They live here so
-- lua/oil/adapters/files.lua stays close to upstream.
--
-- All of them read entry meta that the files adapter already fetches when a
-- column declares require_stat, so beyond that one stat per entry they cost
-- nothing. The exception is `count`, which reads each subdirectory, and is
-- therefore off unless asked for.
--
-- They render text with spaces and colour, which the left-hand column parser
-- cannot read back, so they are display only: putting one in `columns` errors
-- at parse time rather than misparsing the line.
local columns = require("oil.columns")
local constants = require("oil.constants")

local FIELD_META = constants.FIELD_META
local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE

local M = {}

local function display_only(name)
  return function()
    error(
      string.format(
        "oil column %q is display only and belongs in right_columns, not columns",
        name
      )
    )
  end
end

local function stat_of(entry)
  local meta = entry[FIELD_META]
  return meta and meta.stat
end

-- modified --------------------------------------------------------------------

local MINUTE, HOUR, DAY, WEEK, MONTH, YEAR = 60, 3600, 86400, 604800, 2592000, 31536000

---@param age integer seconds
---@return string
local function relative(age)
  if age < MINUTE then
    return "just now"
  elseif age < HOUR then
    return string.format("%dm ago", math.floor(age / MINUTE))
  elseif age < DAY then
    return string.format("%dh ago", math.floor(age / HOUR))
  elseif age < WEEK then
    return string.format("%dd ago", math.floor(age / DAY))
  elseif age < MONTH then
    return string.format("%dw ago", math.floor(age / WEEK))
  elseif age < YEAR then
    return string.format("%dmo ago", math.floor(age / MONTH))
  else
    return string.format("%dy ago", math.floor(age / YEAR))
  end
end

-- Fixed English names: os.date's %a and %b follow the system locale, which on
-- this machine gives 六 and 3月.
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

---Start of the calendar day that `now` falls in, local time.
---@param now integer
---@return integer
local function midnight_of(now)
  local t = os.date("*t", now)
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
end

---Ages while fresh, dates once age stops being informative.
---@param sec integer mtime
---@param now integer
---@return string
local function natural(sec, now)
  local age = now - sec
  if age < 6 * HOUR and age >= 0 then
    return relative(age)
  end
  local midnight = midnight_of(now)
  local t = os.date("*t", sec)
  local clock = string.format("%02d:%02d", t.hour, t.min)
  if sec >= midnight then
    return "today " .. clock
  elseif sec >= midnight - DAY then
    return "yest. " .. clock -- as wide as "today", so the column never shifts
  elseif sec >= midnight - 6 * DAY then
    return WEEKDAYS[t.wday] .. " " .. clock
  elseif t.year == os.date("*t", now).year then
    return string.format("%d %s", t.day, MONTHS[t.month])
  else
    return string.format("%d-%02d-%02d", t.year, t.month, t.day)
  end
end

---Highlight by recency, on the calendar like the text: today, the last week,
---older.
---@param sec integer
---@param now integer
---@return string
local function recency_group(sec, now)
  local midnight = midnight_of(now)
  if sec >= midnight then
    return "OilModifiedToday"
  elseif sec >= midnight - 6 * DAY then
    return "OilModifiedWeek"
  else
    return "OilModifiedOld"
  end
end

M.modified = {
  require_stat = true,

  ---@param conf? {style?: "natural"|"relative"|"absolute", format?: string}
  render = function(entry, conf)
    local stat = stat_of(entry)
    if not stat then
      return columns.EMPTY
    end
    local sec = stat.mtime.sec
    local now = os.time()
    local style = conf and conf.style or "natural"
    local text
    if style == "natural" then
      text = natural(sec, now)
    elseif style == "relative" then
      text = relative(math.max(now - sec, 0))
    elseif style == "absolute" then
      text = os.date(conf and conf.format or "%y-%m-%d %H:%M", sec)
    else
      error(string.format("modified: unknown style %q (natural, relative or absolute)", style))
    end
    return { text, recency_group(sec, now) }
  end,

  get_sort_value = function(entry)
    local stat = stat_of(entry)
    return stat and stat.mtime.sec or 0
  end,

  ---Widest value the style can produce, so the column keeps one width in
  ---every directory instead of fitting the widest value on screen.
  ---@param conf? {style?: string, format?: string}
  ---@return integer
  width = function(conf)
    local style = conf and conf.style or "natural"
    if style == "natural" then
      return #"today 00:00" -- also "yest. 00:00" and "2023-03-15"
    elseif style == "relative" then
      return #"12mo ago" -- also "just now"
    else
      -- a strftime format's width does not depend on the date, apart from
      -- locale-dependent names, which absolute leaves to the user
      return vim.api.nvim_strwidth(os.date(conf and conf.format or "%y-%m-%d %H:%M", 0))
    end
  end,

  parse = display_only("modified"),
}

-- filesize --------------------------------------------------------------------

---@param size integer
---@return string
---Like ls -h: one decimal below 10, none above, so never more than 4 characters
---(999k, 3.0M, 45M, 1.2G) up to 999T. The two thresholds are where rounding
---would otherwise print a fifth character: 9.95 rounds to "10.0", and 999.5 of
---the smaller unit rounds to "1000".
---@param size integer
---@return string
local function human_size(size)
  local units = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }
  for _, u in ipairs(units) do
    if size >= u[1] * 0.9995 then
      local v = size / u[1]
      if v < 9.95 then
        return string.format("%.1f%s", v, u[2])
      end
      return string.format("%.0f%s", v, u[2])
    end
  end
  return tostring(size)
end

-- Colour by magnitude. Each threshold is the lowest size that takes its group.
local SIZE_TIERS = {
  { 10e9, "OilSizeXL" },
  { 1e9, "OilSizeL" },
  { 100e6, "OilSizeM" },
  { 10e6, "OilSizeS" },
  { 1e6, "OilSizeXS" },
}

---@param size integer
---@return string
local function size_group(size)
  for _, tier in ipairs(SIZE_TIERS) do
    if size >= tier[1] then
      return tier[2]
    end
  end
  return "OilRightColumn"
end

M.filesize = {
  require_stat = true,

  ---@param conf? {min?: integer, below?: string}
  render = function(entry, conf)
    -- a directory's stat size is its block allocation, which means nothing here
    if entry[FIELD_TYPE] == "directory" then
      return ""
    end
    local stat = stat_of(entry)
    if not stat then
      return columns.EMPTY
    end
    local min = conf and conf.min or 0
    if stat.size < min then
      return conf and conf.below or ""
    end
    return { human_size(stat.size), size_group(stat.size) }
  end,

  get_sort_value = function(entry)
    local stat = stat_of(entry)
    return stat and stat.size or 0
  end,

  ---@param conf? {below?: string}
  ---@return integer
  width = function(conf)
    return math.max(4, conf and conf.below and vim.api.nvim_strwidth(conf.below) or 0)
  end,

  parse = display_only("filesize"),
}

-- permissions_hint -------------------------------------------------------------

local S_IWUSR, S_IXUSR = 128, 64 -- 0200, 0100

M.permissions_hint = {
  require_stat = true,

  ---Only the unusual cases: read-only, or an executable regular file.
  render = function(entry)
    local stat = stat_of(entry)
    if not stat or not stat.mode then
      return ""
    end
    local readonly = bit.band(stat.mode, S_IWUSR) == 0
    local executable = entry[FIELD_TYPE] == "file" and bit.band(stat.mode, S_IXUSR) ~= 0
    if readonly and executable then
      return { "ro x", "OilPermissionHint" }
    elseif readonly then
      return { "ro", "OilPermissionHint" }
    elseif executable then
      return { "x", "OilPermissionHint" }
    end
    return ""
  end,

  width = function()
    return #"ro x"
  end,

  parse = display_only("permissions_hint"),
}

-- count -----------------------------------------------------------------------

M.count = {
  ---Number of entries in a subdirectory. Reads the directory, so this is the
  ---one column here with a cost per entry. With `max`, reading stops after
  ---max + 1 entries and shows "max+", which keeps large directories cheap.
  ---@param conf? {max?: integer|false}
  render = function(entry, conf, bufnr)
    if entry[FIELD_TYPE] ~= "directory" then
      return ""
    end
    local name = entry[FIELD_NAME]
    if name == ".." then
      return ""
    end
    local dir = require("oil").get_current_dir(bufnr)
    if not dir then
      return ""
    end
    local handle = vim.uv.fs_scandir(dir .. name)
    if not handle then
      return ""
    end
    local max = conf and conf.max
    if max == nil then
      max = 9
    end
    local n = 0
    while vim.uv.fs_scandir_next(handle) do
      n = n + 1
      if max and n > max then
        return { max .. "+", "OilRightColumn" }
      end
    end
    return { tostring(n), "OilRightColumn" }
  end,

  ---@param conf? {max?: integer|false}
  ---@return integer
  width = function(conf)
    local max = conf and conf.max
    if max == nil then
      max = 9
    end
    -- exact counts have no bound; the renderer then fits the widest value
    return max and #(max .. "+") or 0
  end,

  parse = display_only("count"),
}

---Register every column above with oil.
M.register = function()
  for name, def in pairs(M) do
    if type(def) == "table" then
      columns.register(name, def)
    end
  end
end

return M
