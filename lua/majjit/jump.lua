local M = {}

local function is_user_window(window, majjit_buffer)
  if not vim.api.nvim_win_is_valid(window) then
    return false
  end
  local config = vim.api.nvim_win_get_config(window)
  if config.relative and config.relative ~= "" then
    return false
  end

  local buffer = vim.api.nvim_win_get_buf(window)
  return buffer ~= majjit_buffer
    and vim.api.nvim_buf_is_valid(buffer)
    and vim.fn.buflisted(buffer) == 1
    and vim.bo[buffer].buftype == ""
end

local function find_user_window(preferred, majjit_buffer)
  if preferred and is_user_window(preferred, majjit_buffer) then
    return preferred
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if is_user_window(window, majjit_buffer) then
        return window
      end
    end
  end
end

local function preview_name(commit_id, path)
  return "majjit://" .. commit_id .. "/" .. path
end

local function find_buffer(name)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_get_name(buffer) == name then
      return buffer
    end
  end
end

local function focus_buffer(buffer)
  local windows = vim.fn.win_findbuf(buffer)
  if windows[1] then
    vim.api.nvim_set_current_win(windows[1])
    return
  end

  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buffer)
end

function M.focus_historical_file(commit_id, path)
  local buffer = find_buffer(preview_name(commit_id, path))
  if not buffer then
    return false
  end
  focus_buffer(buffer)
  return true
end

function M.open_working_file(root, path, preferred_window, majjit_buffer)
  local full_path = vim.fs.joinpath(root, path)
  if not vim.uv.fs_stat(full_path) then
    return nil, "Path does not exist in the working copy: " .. full_path
  end

  local window = find_user_window(preferred_window, majjit_buffer)
  if window then
    local ok, err = pcall(vim.api.nvim_win_call, window, function()
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end)
    if not ok then
      return nil, tostring(err)
    end
    vim.api.nvim_set_current_win(window)
    return true, nil
  end

  local ok, err = pcall(vim.cmd, "tabedit " .. vim.fn.fnameescape(full_path))
  if not ok then
    return nil, tostring(err)
  end
  return true, nil
end

function M.open_historical_file(commit_id, path, contents)
  if M.focus_historical_file(commit_id, path) then
    return true, nil
  end
  if contents:find("\0", 1, true) then
    return nil, "Cannot preview binary file: " .. path
  end

  local endofline = contents:sub(-1) == "\n"
  if endofline then
    contents = contents:sub(1, -2)
  end
  local lines = vim.split(contents, "\n", {
    plain = true,
    trimempty = false,
  })
  if #lines == 0 then
    lines = { "" }
  end

  vim.cmd.tabnew()
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, preview_name(commit_id, path))
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].fixendofline = false
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].endofline = endofline
  vim.bo[buffer].filetype = vim.filetype.match({ filename = path }) or ""
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
  vim.bo[buffer].readonly = true

  vim.keymap.set("n", "q", function()
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose()
    else
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end, {
    buffer = buffer,
    desc = "Close Majjit file preview",
  })

  return true, nil
end

return M
