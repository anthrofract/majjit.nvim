local M = {}

local function find_target_window(majjit_buffer)
  local majjit_window = vim.fn.win_findbuf(majjit_buffer)[1]
  local tab = vim.api.nvim_win_get_tabpage(majjit_window)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if window ~= majjit_window and vim.api.nvim_win_get_config(window).relative == "" then
      return window
    end
  end
  return majjit_window
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

function M.focus_historical_file(commit_id, path, majjit_buffer)
  local buffer = find_buffer(preview_name(commit_id, path))
  if not buffer then
    return false
  end
  local window = find_target_window(majjit_buffer)
  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_set_current_win(window)
  return true
end

function M.open_working_file(root, path, majjit_buffer)
  local full_path = vim.fs.joinpath(root, path)
  if not vim.uv.fs_stat(full_path) then
    return nil, "Path does not exist in the working copy: " .. full_path
  end

  local window = find_target_window(majjit_buffer)
  local replace_majjit = vim.api.nvim_win_get_buf(window) == majjit_buffer
  local ok, err = pcall(vim.api.nvim_win_call, window, function()
    if replace_majjit then
      local buffer = vim.fn.bufadd(full_path)
      vim.fn.bufload(buffer)
      vim.api.nvim_win_set_buf(window, buffer)
    else
      vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    end
  end)
  if not ok then
    return nil, tostring(err)
  end
  vim.api.nvim_set_current_win(window)
  return true, nil
end

function M.open_historical_file(commit_id, path, contents, majjit_buffer)
  if M.focus_historical_file(commit_id, path, majjit_buffer) then
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

  local window = find_target_window(majjit_buffer)
  local return_buffer = vim.api.nvim_win_get_buf(window)
  local buffer = vim.api.nvim_create_buf(false, true)
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

  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_set_current_win(window)

  vim.keymap.set("n", "q", function()
    local preview_window = vim.fn.win_findbuf(buffer)[1]
    if preview_window and vim.api.nvim_buf_is_valid(return_buffer) then
      vim.api.nvim_win_set_buf(preview_window, return_buffer)
    elseif vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end, {
    buffer = buffer,
    desc = "Close Majjit file preview",
  })

  return true, nil
end

return M
