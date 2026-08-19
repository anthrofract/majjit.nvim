local M = {}

local buffer

local function set_lines(target, lines)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, lines)
  vim.bo[target].modifiable = false
end

local function close()
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd.tabclose()
  else
    vim.api.nvim_buf_delete(0, { force = true })
  end
end

function M.open()
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    local windows = vim.fn.win_findbuf(buffer)
    if windows[1] then
      vim.api.nvim_set_current_win(windows[1])
      return
    end
  end

  local cwd = vim.fn.getcwd()

  vim.cmd.tabnew()
  buffer = vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_set_name(buffer, "Majjit")
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].filetype = "majjit"
  vim.bo[buffer].swapfile = false

  set_lines(buffer, { "Loading..." })

  vim.keymap.set("n", "q", close, {
    buffer = buffer,
    desc = "Close Majjit",
  })

  local target = buffer
  require("majjit.jj").workspace_root(cwd, function(root, err)
    if target ~= buffer or not vim.api.nvim_buf_is_valid(target) then
      return
    end

    if err then
      local lines = vim.split(err, "\n", { plain = true })
      lines[1] = "Error: " .. lines[1]
      set_lines(target, lines)
      return
    end

    set_lines(target, { "repository: " .. root })
  end)
end

return M
