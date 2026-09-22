local extra = require("oil.extra_columns")
local constants = require("oil.constants")

local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE
local FIELD_META = constants.FIELD_META

local DAY = 86400

---@param fields {type?: string, name?: string, size?: integer, mtime?: integer, mode?: integer}
local function entry(fields)
  local e = {}
  e[FIELD_NAME] = fields.name or "x"
  e[FIELD_TYPE] = fields.type or "file"
  e[FIELD_META] = {
    stat = {
      size = fields.size or 0,
      mtime = { sec = fields.mtime or 0 },
      mode = fields.mode or tonumber("644", 8),
    },
  }
  return e
end

local function text_of(chunk)
  return type(chunk) == "table" and chunk[1] or chunk
end
local function group_of(chunk)
  return type(chunk) == "table" and chunk[2] or nil
end

describe("extra_columns", function()
  describe("modified", function()
    local now = os.time()
    -- noon today, so that "today" and "yesterday" are unambiguous
    local t = os.date("*t", now)
    local noon = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })

    it("shows an age while fresh", function()
      assert.equals("just now", text_of(extra.modified.render(entry({ mtime = now - 10 }), { style = "natural" })))
      assert.equals("5m ago", text_of(extra.modified.render(entry({ mtime = now - 5 * 60 }), { style = "natural" })))
      assert.equals("2h ago", text_of(extra.modified.render(entry({ mtime = now - 2 * 3600 }), { style = "natural" })))
    end)

    it("shows today, yesterday, then the weekday", function()
      -- older than 6h but today: needs a time earlier than now - 6h that is still today,
      -- so only assert the shape when the clock allows it
      if now - noon >= 6 * 3600 then
        assert.equals("today 12:00", text_of(extra.modified.render(entry({ mtime = noon }), { style = "natural" })))
      end
      assert.equals("yesterday 12:00", text_of(extra.modified.render(entry({ mtime = noon - DAY }), { style = "natural" })))
      local three_days = noon - 3 * DAY
      local expected = ({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" })[os.date("*t", three_days).wday] .. " 12:00"
      assert.equals(expected, text_of(extra.modified.render(entry({ mtime = three_days }), { style = "natural" })))
    end)

    it("uses fixed English month names and a full date for other years", function()
      local same_year = os.time({ year = t.year, month = 1, day = 15, hour = 12 })
      if now - same_year > 7 * DAY then
        assert.equals("15 Jan", text_of(extra.modified.render(entry({ mtime = same_year }), { style = "natural" })))
      end
      local old = os.time({ year = 2023, month = 3, day = 15, hour = 8 })
      assert.equals("2023-03-15", text_of(extra.modified.render(entry({ mtime = old }), { style = "natural" })))
    end)

    it("colours by calendar recency", function()
      assert.equals("OilModifiedToday", group_of(extra.modified.render(entry({ mtime = now - 10 }), {})))
      assert.equals("OilModifiedWeek", group_of(extra.modified.render(entry({ mtime = noon - DAY }), {})))
      assert.equals("OilModifiedOld", group_of(extra.modified.render(entry({ mtime = noon - 30 * DAY }), {})))
    end)

    it("supports relative and absolute styles", function()
      assert.equals("3d ago", text_of(extra.modified.render(entry({ mtime = now - 3 * DAY }), { style = "relative" })))
      local fixed = os.time({ year = 2024, month = 3, day = 15, hour = 10, min = 30 })
      assert.equals("24-03-15 10:30", text_of(extra.modified.render(entry({ mtime = fixed }), { style = "absolute" })))
      assert.equals("2024", text_of(extra.modified.render(entry({ mtime = fixed }), { style = "absolute", format = "%Y" })))
    end)

    it("rejects an unknown style loudly", function()
      assert.has_error(function()
        extra.modified.render(entry({ mtime = now }), { style = "fancy" })
      end)
    end)
  end)

  describe("filesize", function()
    it("shows nothing below the threshold, or the placeholder if given", function()
      assert.equals("", text_of(extra.filesize.render(entry({ size = 500 }), { min = 100e3 })))
      assert.equals("--", text_of(extra.filesize.render(entry({ size = 500 }), { min = 100e3, below = "--" })))
      assert.equals("250k", text_of(extra.filesize.render(entry({ size = 250e3 }), { min = 100e3 })))
    end)

    it("shows nothing for directories", function()
      assert.equals("", text_of(extra.filesize.render(entry({ type = "directory", size = 4096 }), {})))
    end)

    it("colours by magnitude", function()
      local cases = {
        { 250e3, "OilRightColumn" },
        { 3e6, "OilSizeXS" },
        { 45e6, "OilSizeS" },
        { 400e6, "OilSizeM" },
        { 2e9, "OilSizeL" },
        { 20e9, "OilSizeXL" },
      }
      for _, c in ipairs(cases) do
        assert.equals(c[2], group_of(extra.filesize.render(entry({ size = c[1] }), {})), tostring(c[1]))
      end
    end)
  end)

  describe("permissions_hint", function()
    it("is empty in the common case", function()
      assert.equals("", text_of(extra.permissions_hint.render(entry({ mode = tonumber("644", 8) }))))
      -- a directory's execute bit is the search bit, not worth a hint
      assert.equals("", text_of(extra.permissions_hint.render(entry({ type = "directory", mode = tonumber("755", 8) }))))
    end)

    it("flags read-only and executable files", function()
      assert.equals("ro", text_of(extra.permissions_hint.render(entry({ mode = tonumber("444", 8) }))))
      assert.equals("x", text_of(extra.permissions_hint.render(entry({ mode = tonumber("755", 8) }))))
      assert.equals("ro x", text_of(extra.permissions_hint.render(entry({ mode = tonumber("555", 8) }))))
    end)
  end)

  it("refuses to be parsed as a left-hand column", function()
    assert.has_error(function()
      extra.filesize.parse("250k rest")
    end)
  end)
end)
