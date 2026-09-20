local git_status = require("oil.git_status")

---Create a scratch buffer with a given name and filetype.
---@param name string
---@param filetype string
---@return integer
local function make_buf(name, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = filetype
  return bufnr
end

describe("git_status", function()
  describe("should_load_status", function()
    it("accepts an oil buffer on the files adapter", function()
      local bufnr = make_buf("oil:///home/user/project/", "oil")
      assert.is_true(git_status.should_load_status(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    -- Buffer numbers are recycled. An oil buffer can be wiped and its number
    -- reused by a normal file, leaving the buffer-local BufWritePost autocmd
    -- attached to a non-oil buffer. Without this guard the url rewrite below
    -- produces a schemeless path and vim.uri_to_fname raises "URI must contain
    -- a scheme" on every save.
    it("rejects a recycled buffer number now holding a normal file", function()
      local bufnr = make_buf("/home/user/project/README.md", "markdown")
      assert.is_false(git_status.should_load_status(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    -- The url rewrite is `oil` -> `file`, so oil-ssh://host/path would become
    -- file-ssh://host/path and yield a path that is not local. Skipping other
    -- adapters is correct behavior, not a missing feature.
    it("rejects adapters other than files", function()
      for _, name in ipairs({ "oil-ssh://host/path/", "oil-trash:///home/user/" }) do
        local bufnr = make_buf(name, "oil")
        assert.is_false(git_status.should_load_status(bufnr), name .. " should be skipped")
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)
  end)

  describe("parse_git_status", function()
    it("reads index and working tree codes", function()
      local status = git_status.parse_git_status("M  staged.lua\n M unstaged.lua\n?? new.lua\n", "")
      assert.are.same({ index = "M", working_tree = " " }, status["staged.lua"])
      assert.are.same({ index = " ", working_tree = "M" }, status["unstaged.lua"])
      assert.are.same({ index = "?", working_tree = "?" }, status["new.lua"])
    end)

    it("rolls nested paths up to the top-level directory", function()
      local status = git_status.parse_git_status(" M src/deep/file.lua\n", "")
      assert.are.same({ index = " ", working_tree = "M" }, status["src"])
      assert.is_nil(status["src/deep/file.lua"])
    end)

    it("marks ls-tree entries with no status as unmodified", function()
      local status = git_status.parse_git_status("", "tracked.lua\n")
      assert.are.same({ index = " ", working_tree = " " }, status["tracked.lua"])
    end)

    it("unquotes names git escaped", function()
      local status = git_status.parse_git_status('?? "sp ace\\".md"\n', "")
      assert.are.same({ index = "?", working_tree = "?" }, status['sp ace".md'])
    end)
  end)
end)
