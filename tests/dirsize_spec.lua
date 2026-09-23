require("plenary.async").tests.add_to_env()
local dirsize = require("oil.dirsize")
local TmpDir = require("tests.tmpdir")

---@param path string
---@param bytes integer
local function write(path, bytes)
  local f = assert(io.open(path, "w"))
  f:write(string.rep("x", bytes))
  f:close()
end

a.describe("dirsize", function()
  local tmpdir
  local root

  a.before_each(function()
    tmpdir = TmpDir.new()
    root = vim.fn.fnamemodify(tmpdir.path, ":p"):gsub("/$", "")
    tmpdir:create({ "d/", "d/sub/", "e/" })
    write(root .. "/d/a", 300)
    write(root .. "/d/sub/b", 200)
    for i = 1, 30 do
      write(root .. "/e/f" .. i, 10)
    end
    dirsize.clear()
  end)

  a.after_each(function()
    if tmpdir then
      tmpdir:dispose()
    end
  end)

  a.it("sums every file under a directory, exactly", function()
    local r = dirsize.get(root .. "/d", { mode = "exact", async = false }, nil, function() end)
    assert.same({ bytes = 500, capped = false }, r)
  end)

  a.it("stops at the budget and marks the result as a lower bound", function()
    local r = dirsize.get(root .. "/e", { mode = "budget", max_files = 10, async = false }, nil, function() end)
    assert.is_true(r.capped)
    assert.equals(110, r.bytes) -- 11 files seen: the budget plus the one that reveals there are more
    local under = dirsize.get(root .. "/d", { mode = "budget", max_files = 10, async = false }, nil, function() end)
    assert.same({ bytes = 500, capped = false }, under)
  end)

  a.it("returns nil first in async mode, then calls back once the size is cached", function()
    local called = 0
    local conf = { mode = "exact", async = true }
    local first = dirsize.get(root .. "/d", conf, nil, function()
      called = called + 1
    end)
    assert.is_nil(first)
    for _ = 1, 300 do
      if called > 0 then
        break
      end
      a.util.sleep(10)
    end
    assert.equals(1, called)
    assert.same({ bytes = 500, capped = false }, dirsize.get(root .. "/d", conf, nil, function() end))
  end)

  a.it("serves a cached result without walking again", function()
    local conf = { mode = "exact", async = false }
    dirsize.get(root .. "/d", conf, 1, function() end)
    write(root .. "/d/sub/c", 1000) -- d's own mtime is untouched: a nested change
    assert.same({ bytes = 500, capped = false }, dirsize.get(root .. "/d", conf, 1, function() end))
  end)

  a.it("drops the cache when the directory's own mtime changes", function()
    local conf = { mode = "exact", async = false }
    dirsize.get(root .. "/d", conf, 1, function() end)
    write(root .. "/d/c", 1000)
    assert.same({ bytes = 1500, capped = false }, dirsize.get(root .. "/d", conf, 2, function() end))
  end)

  a.it("drops the cache when the TTL has passed", function()
    local conf = { mode = "exact", async = false, cache_ttl = 0 }
    dirsize.get(root .. "/d", conf, nil, function() end)
    write(root .. "/d/sub/c", 1000)
    -- ttl 0: anything older than this second is stale; force the boundary
    a.util.sleep(1100)
    assert.same({ bytes = 1500, capped = false }, dirsize.get(root .. "/d", conf, nil, function() end))
  end)

  a.it("drops everything after an oil mutation", function()
    local conf = { mode = "exact", async = false }
    dirsize.get(root .. "/d", conf, 1, function() end)
    write(root .. "/d/sub/c", 1000)
    vim.api.nvim_exec_autocmds("User", { pattern = "OilMutationComplete" })
    assert.same({ bytes = 1500, capped = false }, dirsize.get(root .. "/d", conf, 1, function() end))
  end)

  a.it("remembers a failure instead of retrying it on every call", function()
    local conf = { mode = "exact", async = false }
    local notified = 0
    local orig = vim.notify
    vim.notify = function()
      notified = notified + 1
    end
    local r1 = dirsize.get(root .. "/does-not-exist", conf, nil, function() end)
    local r2 = dirsize.get(root .. "/does-not-exist", conf, nil, function() end)
    vim.notify = orig
    assert.is_false(r1)
    assert.is_false(r2)
    assert.equals(1, notified)
  end)

  a.it("rejects an unknown mode loudly", function()
    assert.has_error(function()
      dirsize.get(root .. "/d", { mode = "fast", async = false }, nil, function() end)
    end)
  end)
end)
