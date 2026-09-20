-- Vendored from refractalize/oil-git-status.nvim at commit 4b5cf53,
-- lua/oil-git-status/system.lua. Copyright (c) 2025 Tim Macfarlane, MIT.
-- Full license text in LICENSE-oil-git-status at the repository root.
-- Unmodified except for this header.

local function system(cmd, opts, cb)
  local stdout
  local stderr

  vim.fn.jobstart(cmd, {
    cwd = opts.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, code)
      cb({
        code = code,
        stdout = stdout,
        stderr = stderr,
      })
    end,
    on_stdout = function(_, lines)
      stdout = vim.fn.join(lines, "\n")
    end,
    on_stderr = function(_, lines)
      stderr = vim.fn.join(lines, "\n")
    end,
  })
end

return {
  system = vim.system or system,
}
