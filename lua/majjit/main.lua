local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local buffer
local namespace = vim.api.nvim_create_namespace("majjit")
local repository = require("majjit.repository")

local function set_lines(target, lines)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(target, namespace, 0, -1)
  ansi.once(target)
  vim.bo[target].modifiable = false
end

local function highlight_header(target, root, revset)
  local repository_label = "repository: "
  local revset_label = "  revset: "
  local root_start = #repository_label
  local revset_label_start = root_start + #root
  local revset_start = revset_label_start + #revset_label

  vim.api.nvim_buf_set_extmark(target, namespace, 0, 0, {
    end_col = root_start,
    hl_group = "Label",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, root_start, {
    end_col = revset_label_start,
    hl_group = "String",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, revset_label_start, {
    end_col = revset_start,
    hl_group = "Label",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, revset_start, {
    end_col = revset_start + #revset,
    hl_group = "String",
  })
end

local function close()
  repository.cancel()

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
  vim.wo.cursorline = true

  set_lines(buffer, { "Loading..." })

  vim.keymap.set("n", "q", close, {
    buffer = buffer,
    desc = "Close Majjit",
  })

  local target = buffer
  repository.load(cwd, function(state, err)
    if not vim.api.nvim_buf_is_valid(target) then
      return
    end

    if err then
      local lines = vim.split(err, "\n", { plain = true })
      lines[1] = "Error: " .. lines[1]
      set_lines(target, lines)
      return
    end

    local lines = {
      "repository: " .. state.root .. "  revset: " .. state.revset,
      "",
    }
    vim.list_extend(lines, state.log.lines)
    set_lines(target, lines)
    highlight_header(target, state.root, state.revset)

    local windows = vim.fn.win_findbuf(target)
    if windows[1] and state.log.current_line then
      vim.api.nvim_win_set_cursor(windows[1], { state.log.current_line + 2, 0 })
    end
  end)
end

return M
