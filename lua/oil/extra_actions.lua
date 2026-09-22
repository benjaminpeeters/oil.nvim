-- Fork additions to oil's actions.
--
-- They live in their own file, not in actions.lua, so that file stays close to
-- upstream and keeps merging cleanly. actions.lua copies every entry from here
-- into its own table, which makes these ordinary actions: "actions.select_split"
-- works in a keymap like any other, and they show up in the help window.
--
-- Nothing here may require("oil.actions") at module scope. actions.lua requires
-- this file while it is itself still loading.
local M = {}

---@return oil.Entry|nil entry
---@return string|nil dir Directory of the current oil buffer, with a trailing slash
local function cursor_entry_and_dir()
  local oil = require("oil")
  return oil.get_cursor_entry(), oil.get_current_dir()
end

---Run a detached job, reporting failure instead of dropping it
---@param cmd string
---@param failure_message string
local function spawn(cmd, failure_message)
  vim.fn.jobstart(cmd, {
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify(failure_message, vim.log.levels.ERROR)
      end
    end,
  })
end

-- Vertical splits are full-height side panels with a fixed width. Horizontal
-- splits stay inside the current column when the window is already part of a
-- vertical split, and span the whole editor otherwise.
local split_commands = {
  left = function()
    vim.cmd("topleft vsplit")
    vim.cmd("vertical resize 80")
  end,
  right = function()
    vim.cmd("botright vsplit")
    vim.cmd("vertical resize 80")
  end,
  up = function(in_vsplit)
    vim.cmd(in_vsplit and "aboveleft split" or "topleft split")
    vim.cmd("resize 20")
  end,
  down = function(in_vsplit)
    vim.cmd(in_vsplit and "belowright split" or "botright split")
    vim.cmd("resize 20")
  end,
}

M.select_split = {
  desc = "Open the entry under the cursor in a split on the given side",
  callback = function(opts)
    local direction = opts and opts.direction
    local make_split = split_commands[direction]
    if not make_split then
      error(
        string.format(
          "select_split: direction must be left, right, up or down, got %s",
          vim.inspect(direction)
        )
      )
    end

    -- Read the entry before splitting: the new window changes what is current
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end

    local in_vsplit = vim.api.nvim_win_get_width(0) < vim.o.columns * 0.9
    make_split(in_vsplit)

    if entry.type == "directory" then
      require("oil.actions").select.callback()
    else
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. entry.name))
      -- Lets the global "-" mapping return to this directory even when the file
      -- was reached through a symlink
      vim.b.oil_origin_directory = dir
    end
  end,
  parameters = {
    direction = {
      type = '"left"|"right"|"up"|"down"',
      desc = "Side on which to open the split",
    },
  },
}

M.yank_path_to_clipboard = {
  desc = "Copy the absolute path of the entry under the cursor to the system clipboard",
  callback = function()
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end
    local name = entry.name
    if entry.type == "directory" then
      name = name .. "/"
    end
    vim.fn.setreg("+", dir .. name)
  end,
}

-- Navigation that remembers where it came from. The working directory itself
-- follows the buffer through config.cd_on_enter; these only record the origin.
--
-- Two different origins, for two different returns:
--   * vim.b.oil_symlink_origin, on the oil buffer entered: parent_or_origin
--     goes back there instead of to the parent, which matters after following
--     a symlink, whose parent is not the directory we came from
--   * vim.b.oil_origin_directory, on a file opened from oil: a global "-"
--     mapping can reopen that directory rather than the file's own parent
M.select_with_origin = {
  desc = "Open the entry under the cursor, remembering the directory it was opened from",
  callback = function()
    local oil = require("oil")
    local origin_dir = oil.get_current_dir() -- before selecting

    require("oil.actions").select.callback()

    -- oil switches buffers asynchronously; the flag has to land on the buffer
    -- that was just entered
    vim.defer_fn(function()
      if vim.bo.filetype == "oil" then
        vim.b.oil_symlink_origin = origin_dir
      else
        vim.b.oil_origin_directory = origin_dir
      end
    end, 50)
  end,
}

M.parent_or_origin = {
  desc = "Go back to the directory we came from, or to the parent",
  callback = function()
    local symlink_origin = vim.b.oil_symlink_origin
    vim.b.oil_symlink_origin = nil -- one-time return

    if symlink_origin then
      require("oil").open(symlink_origin)
    else
      require("oil.actions").parent.callback()
    end
  end,
}

M.open_by_type = {
  desc = "Open the entry with a program chosen by its extension, else the system default",
  callback = function()
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end
    local path = dir .. entry.name

    if entry.name:match("%.pdf$") then
      spawn('xdg-open "' .. path .. '"', "Failed to open PDF")
    elseif entry.name:match("%.md$") then
      spawn('x-terminal-emulator -e nvim "' .. path .. '"', "Failed to open markdown file")
    elseif entry.name:match("%.html?$") then
      spawn('brave-browser "' .. path .. '"', "Failed to open HTML in brave-browser")
    else
      require("oil.actions").open_external.callback()
    end
  end,
}

M.delete_permanently = {
  desc = "Delete the entry under the cursor for good, bypassing the trash, after confirming",
  callback = function()
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end

    local choice = vim.fn.confirm("Permanently delete " .. entry.name .. "?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end

    local target = vim.fn.shellescape(dir .. entry.name)
    -- Read-only trees (common on HPC scratch space) cannot be removed otherwise
    vim.fn.system(string.format("chmod -R u+w %s", target))
    vim.fn.system(string.format("rm -rf %s", target))

    if vim.v.shell_error == 0 then
      vim.notify("Deleted " .. entry.name, vim.log.levels.INFO)
      require("oil.actions").refresh.callback()
    else
      vim.notify("Failed to delete " .. entry.name, vim.log.levels.ERROR)
    end
  end,
}

M.trash_put = {
  desc = "Send the entry under the cursor to the trash with trash-put (trash-cli)",
  callback = function()
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    vim.fn.system(string.format("trash-put %s", vim.fn.shellescape(dir .. entry.name)))

    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to trash " .. entry.name, vim.log.levels.ERROR)
      return
    end
    vim.notify("Trashed: " .. entry.name, vim.log.levels.INFO)

    -- watch_for_changes reloads the buffer; put the cursor back on the same
    -- line once that has happened
    vim.defer_fn(function()
      local new_line = math.min(line, vim.api.nvim_buf_line_count(0))
      pcall(vim.api.nvim_win_set_cursor, 0, { new_line, 0 })
    end, 100)
  end,
}

M.move_to_dir = {
  desc = "Move the entry under the cursor into a fixed directory",
  callback = function(opts)
    local entry, dir = cursor_entry_and_dir()
    if not entry or not dir then
      return
    end

    local target_dir = (opts and opts.dir) or (os.getenv("HOME") .. "/output/")
    local source = vim.fn.shellescape(dir .. entry.name)
    local target = vim.fn.shellescape(target_dir)

    vim.fn.system("mkdir -p " .. target)
    vim.fn.system(string.format("chmod -R u+w %s", source))
    vim.fn.system(string.format("mv %s %s", source, target))

    if vim.v.shell_error == 0 then
      vim.notify(
        "Moved " .. entry.name .. " to " .. vim.fn.fnamemodify(target_dir, ":~"),
        vim.log.levels.INFO
      )
      require("oil.actions").refresh.callback()
    else
      vim.notify("Failed to move " .. entry.name, vim.log.levels.ERROR)
    end
  end,
  parameters = {
    dir = {
      type = "string",
      desc = "Destination directory (default $HOME/output/)",
    },
  },
}

M.open_terminal = {
  desc = "Open a terminal in the current directory: a tmux window inside tmux, else a new terminal",
  callback = function()
    local dir = require("oil").get_current_dir()
    if not dir then
      return
    end

    if os.getenv("TMUX") then
      vim.fn.system("tmux new-window -c " .. vim.fn.shellescape(dir))
      vim.notify("Opened new tmux window in " .. dir, vim.log.levels.INFO)
      return
    end

    local path = dir:gsub("/$", "")
    local quoted = path:gsub("'", "'\\''")
    spawn(
      "x-terminal-emulator -e bash -c \"cd '" .. quoted .. "' && exec $SHELL\"",
      "Failed to start terminal"
    )
    vim.notify("Opened terminal in " .. dir, vim.log.levels.INFO)
  end,
}

M.toggle_right_columns = {
  desc = "Show or hide the right-hand columns for this session (a fast listing on a slow mount)",
  callback = function()
    local enabled = require("oil.view").toggle_right_columns()
    vim.notify("Right-hand columns " .. (enabled and "shown" or "hidden"), vim.log.levels.INFO)
  end,
}

M.wezterm_preview = {
  desc = "Toggle a WezTerm pane that previews the entry under the cursor",
  callback = function()
    require("oil.wezterm_preview").weztermPreview.callback()
  end,
}

return M
