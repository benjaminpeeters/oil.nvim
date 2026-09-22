require("plenary.async").tests.add_to_env()
local test_util = require("tests.test_util")
local TmpDir = require("tests.tmpdir")

-- Every spec runs with cd_on_enter pinned off (tests/test_util.lua), because
-- the others open directories and then :edit relative paths. This one turns it
-- on, and restores the cwd it started from.
a.describe("cd_on_enter", function()
  local tmpdir
  local original_cwd
  local root -- absolute, resolved before any cd: tmpdir.path is relative

  a.before_each(function()
    original_cwd = vim.fn.getcwd()
    tmpdir = TmpDir.new()
    root = vim.fn.fnamemodify(tmpdir.path, ":p"):gsub("/$", "")
    test_util.setup({ cd_on_enter = true })
  end)

  a.after_each(function()
    vim.cmd.cd(original_cwd)
    if tmpdir then
      tmpdir:dispose()
    end
    test_util.reset_editor()
  end)

  a.it("changes the cwd to the directory of an oil buffer on entering it", function()
    tmpdir:create({ "sub/file.txt" })
    test_util.actions.open({ root })
    assert.equals(root, vim.fn.getcwd())

    test_util.actions.open({ root .. "/sub" })
    assert.equals(root .. "/sub", vim.fn.getcwd())
  end)

  a.it("does nothing for buffers that are not oil", function()
    tmpdir:create({ "file.txt" })
    test_util.actions.open({ root })
    local cwd_in_oil = vim.fn.getcwd()
    vim.cmd.edit({ args = { root .. "/file.txt" } })
    assert.equals(cwd_in_oil, vim.fn.getcwd())
  end)

  a.it("is off when the option is off", function()
    test_util.setup({ cd_on_enter = false })
    tmpdir:create({ "file.txt" })
    test_util.actions.open({ root })
    assert.equals(original_cwd, vim.fn.getcwd())
  end)
end)
