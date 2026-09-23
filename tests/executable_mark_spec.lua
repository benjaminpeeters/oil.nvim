require("plenary.async").tests.add_to_env()
local TmpDir = require("tests.tmpdir")
local test_util = require("tests.test_util")

-- Pinned off for every other spec (tests/test_util.lua); turned on here.
a.describe("executable_mark", function()
  local tmpdir
  local root
  local ns = vim.api.nvim_create_namespace("OilExecutable")

  a.before_each(function()
    tmpdir = TmpDir.new()
    root = vim.fn.fnamemodify(tmpdir.path, ":p")
    tmpdir:create({ "run.sh", "notes.txt", "bin/" })
    vim.uv.fs_chmod(root .. "run.sh", tonumber("755", 8))
    vim.uv.fs_chmod(root .. "notes.txt", tonumber("644", 8))
  end)

  a.after_each(function()
    if tmpdir then
      tmpdir:dispose()
    end
    test_util.reset_editor()
  end)

  ---@return table<string, {sign: string|nil, italic: boolean}> by entry name
  local function marks()
    local out = {}
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for lnum, line in ipairs(lines) do
      local name = line:gsub("^/%d+ ", "")
      out[name] = { italic = false }
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
        if m[4].virt_text then
          out[name].sign = m[4].virt_text[1][1]
        elseif m[4].hl_group == "OilExecutable" then
          out[name].italic = true
        end
      end
    end
    return out
  end

  a.it("marks executable files only, without touching the buffer text", function()
    test_util.setup({ view_options = { executable_mark = "*" } })
    test_util.actions.open({ root })
    local m = marks()
    assert.same({ sign = "*", italic = true }, m["run.sh"])
    assert.same({ italic = false }, m["notes.txt"])
    assert.same({ italic = false }, m["bin/"]) -- a directory's x bit is the search bit
    for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      assert.is_nil(line:find("*", 1, true), "the sign must be virtual: " .. line)
    end
  end)

  a.it("uses the configured sign", function()
    test_util.setup({ view_options = { executable_mark = "!" } })
    test_util.actions.open({ root })
    assert.equals("!", marks()["run.sh"].sign)
  end)

  a.it("does nothing when off", function()
    test_util.setup({ view_options = { executable_mark = false } })
    test_util.actions.open({ root })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
  end)

  a.it("gives OilExecutable an italic default without a colour of its own", function()
    test_util.setup({})
    local hl = vim.api.nvim_get_hl(0, { name = "OilExecutable", link = false })
    assert.is_true(hl.italic or false)
    assert.is_nil(hl.fg)
  end)
end)
