-- Preview of the entry under the cursor in a WezTerm split pane: images through
-- `wezterm imgcat`, files through bat, directories through ls.
--
-- Fork addition, exposed as actions.wezterm_preview. Derived from
-- mimikun/oil-image-preview.nvim at commit 47286e4, Copyright (c) 2024 Yuto Tanaka,
-- MIT. Full license text in LICENSE-oil-image-preview at the repository root.

local M = {}

--------------------------------------------------------------------------------
-- Utility Functions (extracted from oil-image-preview.util)
--------------------------------------------------------------------------------

---Debounce a function
---@param func function
---@param wait number
local function debounce(func, wait)
  local timer_id
  ---@vararg any
  return function(...)
    if timer_id ~= nil then
      vim.uv.timer_stop(timer_id)
    end
    local args = { ... }
    timer_id = assert(vim.uv.new_timer())
    vim.uv.timer_start(timer_id, wait, 0, function()
      func(unpack(args))
      timer_id = nil
    end)
  end
end

---Check if image file
---@param url string
local function isImage(url)
  local extension = url:match("^.+(%..+)$")
  local imageExt = { ".bmp", ".jpg", ".jpeg", ".png", ".gif" }

  return vim.iter(imageExt):any(function(ext)
    return extension == ext
  end)
end

---Name of the bat executable. Debian and Ubuntu package it as `batcat`, because
---the name `bat` was already taken there, so a hardcoded "bat" fails on them.
---@return string|nil
local function batCommand()
  for _, name in ipairs({ "bat", "batcat" }) do
    if vim.fn.executable(name) == 1 then
      return name
    end
  end
  vim.notify(
    "WezTerm preview needs bat on PATH to show files (the package installs it as batcat on Debian/Ubuntu)",
    vim.log.levels.ERROR
  )
end

---Get entry absolute path
---@return string ...
local function getEntryAbsolutePath()
  local oil = require("oil")
  local entry = oil.get_cursor_entry()
  local dir = oil.get_current_dir()
  if not entry or not dir then
    return
  end
  return dir .. entry.name, entry, dir
end

--------------------------------------------------------------------------------
-- Preview Implementation
--------------------------------------------------------------------------------

-- State tracking for preview pane IDs per buffer
local preview_pane_state = {}

-- NOTE: ONLY linux
-- NOTE: ONLY macos, linux
---Get the pane id in which neovim is open
---@return number|nil
local function getNeovimWeztermPane()
  local wezterm_pane_id = vim.env.WEZTERM_PANE
  if not wezterm_pane_id then
    vim.notify("Wezterm pane not found", vim.log.levels.ERROR)
    return
  end
  return tonumber(wezterm_pane_id)
end

-- NOTE: ONLY macos, linux
---Activate a wezterm pane using wezterm_pane_id
---@param wezterm_pane_id number
local activeWeztermPane = function(wezterm_pane_id)
  vim.system({ "wezterm", "cli", "activate-pane", "--pane-id", wezterm_pane_id })
end

-- NOTE: ONLY macos, linux
---Open a new wezterm pane, and get its pane id
---@param opt table
local openNewWeztermPane = function(opt)
  local _opt = opt or {}
  local percent = _opt.percent or 30
  local direction = _opt.direction or "right"

  local cmd = {
    "wezterm",
    "cli",
    "split-pane",
    ("--percent=%d"):format(percent),
    ("--%s"):format(direction),
    "--",
    "bash",
  }
  local obj = vim.system(cmd, { text = true }):wait()
  local wezterm_pane_id = assert(tonumber(obj.stdout))

  return wezterm_pane_id
end

-- NOTE: ONLY macos, linux
---Close the wezterm pane for wezterm_pane_id
---@param wezterm_pane_id number
local closeWeztermPane = function(wezterm_pane_id)
  vim.system({
    "wezterm",
    "cli",
    "kill-pane",
    ("--pane-id=%d"):format(wezterm_pane_id),
  })
end

-- NOTE: ONLY macos, linux
---Send command to the wezterm pane
---@param wezterm_pane_id number
---@param command any
local sendCommandToWeztermPane = function(wezterm_pane_id, command)
  -- Send Ctrl+L to clear screen (ASCII 0x0C / form feed)
  vim.fn.system(string.format(
    "printf '\\f' | wezterm cli send-text --no-paste --pane-id=%d",
    wezterm_pane_id
  ))

  -- Small delay to let clear complete
  vim.cmd('sleep 10m')

  -- Send the actual command with newline
  vim.fn.system(string.format(
    "printf '%s\\n' | wezterm cli send-text --no-paste --pane-id=%d",
    command,
    wezterm_pane_id
  ))
end

-- NOTE: ONLY macos, linux
---Get a list of wezterm panes
---@return any
local function listWeztermPanes()
  local cli_result = vim.system({
    "wezterm",
    "cli",
    "list",
    ("--format=%s"):format("json"),
  }, { text = true }):wait()
  local json = vim.json.decode(cli_result.stdout)
  local panes = vim.iter(json):map(function(obj)
    return { pane_id = obj.pane_id, tab_id = obj.tab_id }
  end)

  return panes
end

-- NOTE: ONLY macos, linux
---Get the wezterm pane id where the image preview is displayed
---@return number|nil
local function getPreviewWeztermPaneId()
  local panes = listWeztermPanes()
  local neovim_wezterm_pane_id = getNeovimWeztermPane()
  local current_tab_id = assert(panes:find(function(obj)
    return obj.pane_id == neovim_wezterm_pane_id
  end)).tab_id
  local preview_pane = panes:find(function(obj)
    return --
      obj.tab_id == current_tab_id --
        and tonumber(obj.pane_id) > tonumber(neovim_wezterm_pane_id) -- new pane id should be greater than current pane id
  end)
  return preview_pane ~= nil and preview_pane.pane_id or nil
end

-- NOTE: ONLY macos, linux
---Open the image preview pane and, get the wezterm pane id
---@return number|nil
local function openWeztermPreviewPane()
  local preview_pane_id = getPreviewWeztermPaneId()
  if preview_pane_id == nil then
    preview_pane_id = openNewWeztermPane({ percent = 50, direction = "right" })
  end
  return preview_pane_id
end

-- NOTE: ONLY macos, linux
---Check if opened wezterm image preview pane
---@return boolean
local is_wezterm_preview_open = function()
  return getPreviewWeztermPaneId() ~= nil
end

-- NOTE: ONLY macos, linux
M.weztermPreview = {
  callback = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local stored_pane_id = preview_pane_state[bufnr]
    local augroup_name = "OilImagePreview_" .. bufnr

    -- Toggle: if preview is already open, close it and return
    if stored_pane_id and is_wezterm_preview_open() then
      closeWeztermPane(stored_pane_id)
      preview_pane_state[bufnr] = nil

      -- Clear all autocmds for this buffer's preview
      vim.api.nvim_clear_autocmds({ group = augroup_name })

      vim.notify("Preview closed", vim.log.levels.INFO)
      return
    end

    local oil = require("oil")
    local oil_util = require("oil.util")
    local perviw_entry_id = nil
    local prev_cmd = nil

    local neovim_wezterm_pane_id = getNeovimWeztermPane()

    local updateWeztermPreview = debounce(
      vim.schedule_wrap(function()
        if vim.api.nvim_get_current_buf() ~= bufnr then
          return
        end
        local entry = oil.get_cursor_entry()
        -- Don't update in visual mode. Visual mode implies editing not browsing,
        -- and updating the preview can cause flicker and stutter.
        if entry ~= nil and not oil_util.is_visual_mode() then
          local preview_pane_id = openWeztermPreviewPane()
          -- Store the pane ID in state
          preview_pane_state[bufnr] = preview_pane_id
          activeWeztermPane(neovim_wezterm_pane_id)

          if perviw_entry_id == entry.id then
            return
          end

          -- bat may still be sitting in its pager: quit it before the next command
          if prev_cmd == "bat" or prev_cmd == "batcat" then
            sendCommandToWeztermPane(preview_pane_id, "q")
            prev_cmd = nil
          end

          local path = assert(getEntryAbsolutePath())
          local command = ""
          if entry.type == "directory" then
            local cmd = "ls -l"
            command = command .. ("%s %s"):format(cmd, path)
            prev_cmd = cmd
          elseif entry.type == "file" and isImage(path) then
            local cmd = "wezterm imgcat"
            command = command .. ("%s %s"):format(cmd, path)
            prev_cmd = cmd
          elseif entry.type == "file" then
            local cmd = batCommand()
            if not cmd then
              return
            end
            command = command .. ("%s %s"):format(cmd, path)
            prev_cmd = cmd
          end

          sendCommandToWeztermPane(preview_pane_id, command)
        end
      end),
      50
    )

    updateWeztermPreview()

    -- Create buffer-specific augroup (clear any existing autocmds)
    local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

    local config = require("oil.config")
    if config.preview_win.update_on_cursor_moved then
      vim.api.nvim_create_autocmd("CursorMoved", {
        desc = "Update oil wezterm preview",
        group = augroup,
        buffer = bufnr,
        callback = function()
          updateWeztermPreview()
        end,
      })
    end

    vim.api.nvim_create_autocmd({ "BufLeave", "BufDelete", "VimLeave" }, {
      desc = "Close oil wezterm preview",
      group = augroup,
      buffer = bufnr,
      callback = function()
        local pane_id = preview_pane_state[bufnr]
        if pane_id then
          closeWeztermPane(pane_id)
          preview_pane_state[bufnr] = nil
        end
      end,
    })
  end,
  desc = "Preview with Wezterm",
}

return M
