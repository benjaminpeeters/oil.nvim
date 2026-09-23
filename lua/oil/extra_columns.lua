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

---A directory, or a link to one: the files adapter puts the target's stat in
---meta.link_stat.
local function is_directory(entry)
  if entry[FIELD_TYPE] == "directory" then
    return true
  end
  local meta = entry[FIELD_META]
  return entry[FIELD_TYPE] == "link" and meta ~= nil and meta.link_stat ~= nil and meta.link_stat.type == "directory"
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

---Highlight by recency, on the calendar like the text: today, the 7 days
---before, the 30 days before that, up to 6 months, older.
---@param sec integer
---@param now integer
---@return string
local function recency_group(sec, now)
  local midnight = midnight_of(now)
  -- same rule as the text: an age under 6 hours is fresh whatever the clock
  -- says, so "2h ago" at 01:00 is not coloured as yesterday
  if sec >= midnight or now - sec < 6 * HOUR then
    return "OilModifiedToday"
  elseif sec >= midnight - 7 * DAY then
    return "OilModifiedWeek"
  elseif sec >= midnight - 37 * DAY then
    return "OilModifiedMonth"
  elseif sec >= midnight - 183 * DAY then
    return "OilModifiedHalfYear"
  else
    return "OilModifiedOld"
  end
end

M.modified = {
  require_stat = true,

  ---@param conf? {style?: "natural"|"relative"|"absolute", format?: string, tiers?: boolean}
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
    -- tiers = false: one colour, OilModified, for users who want no gradient
    local group = (conf and conf.tiers == false) and "OilModified" or recency_group(sec, now)
    return { text, group }
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

-- Colour by magnitude. Each threshold is the lowest size that takes its group;
-- the group name carries the threshold.
local SIZE_TIERS = {
  { 10e9, "OilSize10G" },
  { 1e9, "OilSize1G" },
  { 10e6, "OilSize10M" },
  { 1e6, "OilSize1M" },
}

---@param size integer
---@param conf? {tiers?: boolean}
---@return string
local function size_group(size, conf)
  if conf and conf.tiers == false then
    return "OilSize"
  end
  for _, tier in ipairs(SIZE_TIERS) do
    if size >= tier[1] then
      return tier[2]
    end
  end
  return "OilRightColumn"
end

---Below `min` nothing is shown, except two signs for the extremes: empty
---(exactly 0 bytes) and near-empty (under `tiny_max`, default 100 bytes).
---@param bytes integer
---@param conf table|nil
---@return string|table|nil nil when the size should be shown as a number
local function small_size(bytes, conf)
  if bytes == 0 then
    return { conf and conf.empty or "∅", "OilSizeEmpty" }
  end
  local tiny_max = conf and conf.tiny_max or 100
  if bytes < tiny_max then
    return { conf and conf.tiny or "∘", "OilSizeEmpty" }
  end
  local min = conf and conf.min or 0
  if bytes < min then
    return conf and conf.below or ""
  end
  return nil
end

---Size of a directory through oil.dirsize, or nil while it is being computed.
---@return string|table
local function directory_size(entry, conf, bufnr)
  local dirs = conf and conf.dirs
  if not dirs or dirs.mode == nil or dirs.mode == "off" then
    return ""
  end
  local name = entry[FIELD_NAME]
  if name == ".." then
    return ""
  end
  local parent = require("oil").get_current_dir(bufnr)
  if not parent then
    return ""
  end
  local stat = stat_of(entry)
  local result = require("oil.dirsize").get(parent .. name, dirs, stat and stat.mtime.sec, function()
    require("oil.view").refresh_right_columns(bufnr)
  end)
  if result == nil then
    return { "…", "OilRightColumn" } -- in flight, a redraw follows
  elseif result == false then
    return "" -- cannot be known; already reported
  end
  local small = small_size(result.bytes, conf)
  if small then
    return small
  end
  local text = human_size(result.bytes)
  if result.capped then
    text = ">" .. text
  end
  return { text, size_group(result.bytes, conf) }
end

M.filesize = {
  require_stat = true,

  ---@param conf? {min?: integer, below?: string, empty?: string, tiny?: string, tiny_max?: integer, tiers?: boolean, dirs?: table} see oil.dirsize for dirs
  render = function(entry, conf, bufnr)
    -- a directory's own stat size is its block allocation and means nothing;
    -- its real size is a walk, which oil.dirsize does on request
    if is_directory(entry) then
      return directory_size(entry, conf, bufnr)
    end
    local stat = stat_of(entry)
    if not stat then
      return columns.EMPTY
    end
    local small = small_size(stat.size, conf)
    if small then
      return small
    end
    return { human_size(stat.size), size_group(stat.size, conf) }
  end,

  get_sort_value = function(entry)
    local stat = stat_of(entry)
    return stat and stat.size or 0
  end,

  ---@param conf? {below?: string, dirs?: table}
  ---@return integer
  width = function(conf)
    -- 4 for a size, one more for the ">" of a capped directory walk
    local w = (conf and conf.dirs and conf.dirs.mode == "budget") and 5 or 4
    return math.max(w, conf and conf.below and vim.api.nvim_strwidth(conf.below) or 0)
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
