require("plenary.async").tests.add_to_env()
local TmpDir = require("tests.tmpdir")
local test_util = require("tests.test_util")

-- Pinned off for every other spec (tests/test_util.lua); turned on here.
a.describe("right_columns", function()
  local tmpdir
  local root
  local ns = vim.api.nvim_create_namespace("OilRightColumns")

  a.before_each(function()
    tmpdir = TmpDir.new()
    root = vim.fn.fnamemodify(tmpdir.path, ":p")
    test_util.setup({ right_columns = { { "mtime", format = "%Y" } } })
  end)

  a.after_each(function()
    if tmpdir then
      tmpdir:dispose()
    end
    test_util.reset_editor()
  end)

  ---@return string[] lines, table<integer, string> virt text joined per line (1-indexed)
  local function lines_and_columns()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local columns = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
      local parts = {}
      for _, chunk in ipairs(m[4].virt_text) do
        table.insert(parts, chunk[1])
      end
      columns[m[2] + 1] = table.concat(parts)
    end
    return lines, columns
  end

  a.it("draws the column as virtual text, not as buffer text", function()
    tmpdir:create({ "a.txt", "with space.md", "sub/" })
    test_util.actions.open({ root })
    local lines, columns = lines_and_columns()
    local year = os.date("%Y")
    for lnum, line in ipairs(lines) do
      assert.is_nil(line:find(year, 1, true), "line must not contain the date: " .. line)
      assert.equals(year, columns[lnum], "line " .. lnum .. " has no column")
    end
  end)

  -- The whole point of drawing it as virtual text: the parser still sees a
  -- line that ends with the name, so editing the buffer behaves exactly as
  -- without the column. A name with a space is the case that would break if
  -- anything came after it in the text.
  a.it("does not affect renaming by editing the buffer", function()
    tmpdir:create({ "with space.md", "other.txt" })
    test_util.actions.open({ root })
    test_util.actions.focus("with space.md")
    vim.bo.modifiable = true
    vim.cmd.normal({ args = { "ciwrenamed" }, bang = true })
    test_util.actions.save()
    tmpdir:assert_fs({
      ["renamed space.md"] = "with space.md",
      ["other.txt"] = "other.txt",
    })
  end)

  a.it("is absent when the option is empty", function()
    test_util.setup({ right_columns = {} })
    tmpdir:create({ "a.txt" })
    test_util.actions.open({ root })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
  end)
end)
