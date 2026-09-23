-- Sizes of directories, for the filesize column. Fork addition.
--
-- A directory's own stat size is its entry-list allocation and says nothing
-- about its contents. Knowing the real size means walking everything under it,
-- which is unbounded work, so this module exists to keep that work bounded,
-- off the render path, and done once:
--
--   mode      "budget": walk stops after max_files files and the result is a
--             lower bound (`capped`); "exact": walk everything.
--   async     true: render shows a placeholder and the size arrives later, via
--             a re-render of the right-hand columns only; false: the render
--             waits for the walk.
--   cache_ttl seconds a result stays valid. A result is also dropped when the
--             directory's own mtime changes (a direct entry added or removed)
--             and when oil completes a mutation anywhere. A change made outside
--             oil deep inside a directory is not detectable cheaply; the TTL is
--             what bounds that staleness.
--   source    "walk" (find, see below) or "duc", a pre-built index kept up to
--             date out of band (`duc index <root>` from a timer), read with one
--             call per listing. Untested here: duc is not installed on the
--             machine this was written on. Failures are reported, never hidden.
--
-- The walk is GNU find printing file sizes, summed here, with `head` cutting
-- it off for the budget. Files only, no symlink following, apparent sizes,
-- the same numbers the filesize column shows for files.
local M = {}

---@class oil.DirSizeResult
---@field bytes integer
---@field capped boolean true when the budget stopped the walk: bytes is a lower bound

-- A cached `false` is a remembered failure: shown as nothing, not retried
-- until the TTL passes. Without it a failing walk would run on every render.
---@type table<string, {result: oil.DirSizeResult|false, at: integer, mtime: integer|nil}>
local cache = {}
---@type table<string, fun()[]> callbacks waiting on a walk in flight
local pending = {}
---@type table<string, true> duc listings already fetched for a parent
local duc_listed = {}
---@type table<string, fun()[]> callbacks waiting on a duc listing in flight
local duc_pending = {}
---@type table<string, true> duc failures already reported, one per parent
local duc_reported = {}

M.clear = function()
  cache = {}
  duc_listed = {}
end

---@param path string directory, no trailing slash
---@param conf table the `dirs` conf of the filesize column
---@param mtime integer|nil the directory's own mtime, from its stat
---@return oil.DirSizeResult|false|nil nil when unknown, false when known to have failed
local function cached(path, conf, mtime)
  local hit = cache[path]
  if not hit then
    return nil
  end
  local ttl = conf.cache_ttl or 300
  if os.time() - hit.at > ttl or (mtime and hit.mtime and mtime ~= hit.mtime) then
    cache[path] = nil
    return nil
  end
  return hit.result
end

local function store(path, result, mtime)
  cache[path] = { result = result, at = os.time(), mtime = mtime }
end

---@param stdout string lines of byte counts
---@param max_files integer|nil
---@return oil.DirSizeResult
local function sum_lines(stdout, max_files)
  local total, n = 0, 0
  for line in stdout:gmatch("[^\n]+") do
    local bytes = tonumber(line)
    if bytes then
      total = total + bytes
      n = n + 1
    end
  end
  return { bytes = total, capped = max_files ~= nil and n > max_files }
end

---The walk command. With a budget, head asks for one line more than the
---budget so that reaching it is distinguishable from exactly filling it.
---@param path string
---@param conf table
---@return string[] cmd
---@return integer|nil max_files
local function walk_command(path, conf)
  if conf.mode == "budget" then
    local max_files = conf.max_files or 5000
    return {
      "sh",
      "-c",
      [[find "$1" -type f -printf '%s\n' 2>/dev/null | head -n "$2"]],
      "sh",
      path,
      tostring(max_files + 1),
    }, max_files
  elseif conf.mode == "exact" then
    return { "sh", "-c", [[find "$1" -type f -printf '%s\n' 2>/dev/null]], "sh", path }, nil
  end
  error(string.format("dirsize: mode must be off, budget or exact, got %s", vim.inspect(conf.mode)))
end

---Run the walk, synchronously or not.
---@param path string
---@param conf table
---@param mtime integer|nil
---@param on_done fun(result: oil.DirSizeResult|nil)
local function walk(path, conf, mtime, on_done)
  local cmd, max_files = walk_command(path, conf)
  local function finish(out)
    if out.code ~= 0 and out.stdout == "" then
      -- find itself failed (not a permission problem inside the tree, which
      -- 2>/dev/null hides and which just makes the sum a lower bound)
      vim.notify(
        string.format("dirsize: %s failed on %s: %s", cmd[1], path, vim.trim(out.stderr or "")),
        vim.log.levels.WARN
      )
      store(path, false, mtime)
      on_done(false)
      return
    end
    local result = sum_lines(out.stdout or "", max_files)
    store(path, result, mtime)
    on_done(result)
  end
  if conf.async == false then
    finish(vim.system(cmd, { text = true }):wait())
  else
    vim.system(cmd, { text = true }, function(out)
      vim.schedule(function()
        finish(out)
      end)
    end)
  end
end

---duc knows every directory under an indexed root, so one call per parent
---fills the cache for all its subdirectories at once.
---@param parent string directory whose children are wanted, no trailing slash
---@param conf table
---@param on_done fun()
local function duc_listing(parent, conf, on_done)
  if duc_listed[parent] then
    on_done()
    return
  end
  if duc_pending[parent] then
    table.insert(duc_pending[parent], on_done)
    return
  end
  duc_pending[parent] = { on_done }
  local cmd = { "duc", "ls", "--bytes", "--dirs-only", "--apparent", parent }
  if conf.duc_database then
    table.insert(cmd, "--database=" .. conf.duc_database)
  end
  local function done()
    local waiting = duc_pending[parent]
    duc_pending[parent] = nil
    for _, cb in ipairs(waiting) do
      cb()
    end
  end
  local function finish(out)
    if out.code ~= 0 then
      if not duc_reported[parent] then
        duc_reported[parent] = true
        vim.notify(
          string.format(
            "dirsize: duc has no index for %s (%s). Sizes stay blank; run `duc index` on a root above it.",
            parent,
            vim.trim(out.stderr or "")
          ),
          vim.log.levels.WARN
        )
      end
      duc_listed[parent] = true -- do not ask again this session
      done()
      return
    end
    for line in (out.stdout or ""):gmatch("[^\n]+") do
      local bytes, name = line:match("^%s*(%d+)%s+(.-)/?$")
      if bytes and name then
        store(parent .. "/" .. name, { bytes = tonumber(bytes), capped = false }, nil)
      end
    end
    duc_listed[parent] = true
    done()
  end
  if conf.async == false then
    finish(vim.system(cmd, { text = true }):wait())
  else
    vim.system(cmd, { text = true }, function(out)
      vim.schedule(function()
        finish(out)
      end)
    end)
  end
end

---Size of a directory: from the cache, or computed. In async mode a miss
---returns nil now and calls on_ready later, once, when the size is in the
---cache; a re-render then finds it.
---@param path string directory, no trailing slash
---@param conf table the `dirs` conf: mode, max_files, async, cache_ttl, source
---@param mtime integer|nil the directory's own mtime, for invalidation
---@param on_ready fun()
---@return oil.DirSizeResult|false|nil nil while unknown (async, in flight), false when it cannot be known
M.get = function(path, conf, mtime, on_ready)
  local hit = cached(path, conf, mtime)
  if hit ~= nil then
    return hit
  end

  if conf.source == "duc" then
    local parent = vim.fn.fnamemodify(path, ":h")
    if not duc_listed[parent] then
      duc_listing(parent, conf, on_ready)
    end
    if duc_listed[parent] then
      -- listed (synchronously just now, or earlier): absent means duc does not know it
      local r = cached(path, conf, mtime)
      return r == nil and false or r
    end
    return nil
  end

  if pending[path] then
    table.insert(pending[path], on_ready)
    return nil
  end
  pending[path] = { on_ready }
  local result
  walk(path, conf, mtime, function(r)
    result = r
    local waiting = pending[path]
    pending[path] = nil
    for _, cb in ipairs(waiting) do
      cb()
    end
  end)
  return result -- set only in sync mode
end

vim.api.nvim_create_autocmd("User", {
  pattern = "OilMutationComplete",
  desc = "Directory sizes: forget everything after oil changed the filesystem",
  callback = M.clear,
})

return M
