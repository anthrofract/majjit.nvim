local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local HEADER_LINE_COUNT = 2
local buffer
local directory
local log = require("majjit.log")
local namespace = vim.api.nvim_create_namespace("majjit")
local repository = require("majjit.repository")
local state

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

local function capture_selection(target)
  if not state then
    return nil, nil
  end

  local windows = vim.fn.win_findbuf(target)
  if not windows[1] then
    return nil, nil
  end

  local window = windows[1]
  local cursor = vim.api.nvim_win_get_cursor(window)
  local selection = {
    column = cursor[2],
    row = cursor[1],
  }
  local entry, offset = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
  if entry and entry.kind == "commit" then
    selection.change_id = entry.change_id
    selection.offset = offset
  end

  local view = vim.api.nvim_win_call(window, vim.fn.winsaveview)
  return selection, view
end

local function restore_selection(target, next_state, selection, view)
  local windows = vim.fn.win_findbuf(target)
  if not windows[1] then
    return
  end

  local row
  if selection and selection.change_id then
    local commit = log.find_commit(next_state.log, selection.change_id)
    if commit then
      row = commit.line + math.min(selection.offset, #commit.lines - 1) + HEADER_LINE_COUNT
    end
  elseif selection then
    row = selection.row
  end
  row = row or (next_state.log.current_line and next_state.log.current_line + HEADER_LINE_COUNT)
  row = math.max(1, math.min(row or 1, vim.api.nvim_buf_line_count(target)))

  local line = vim.api.nvim_buf_get_lines(target, row - 1, row, false)[1]
  local column = math.min(selection and selection.column or 0, #line)
  local window = windows[1]
  if view then
    view.lnum = row
    view.col = column
    vim.api.nvim_win_call(window, function()
      vim.fn.winrestview(view)
    end)
  else
    vim.api.nvim_win_set_cursor(window, { row, column })
  end
end

local function render(target, next_state)
  local selection, view = capture_selection(target)
  local lines = {
    "repository: " .. next_state.root .. "  revset: " .. next_state.revset,
    "",
  }
  vim.list_extend(lines, next_state.log.lines)
  set_lines(target, lines)
  highlight_header(target, next_state.root, next_state.revset)
  restore_selection(target, next_state, selection, view)
  state = next_state
end

local function load(target)
  repository.load(state and state.root or directory, function(next_state, err)
    if target ~= buffer or not vim.api.nvim_buf_is_valid(target) then
      return
    end

    if err then
      if state then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      else
        local lines = vim.split(err, "\n", { plain = true })
        lines[1] = "Error: " .. lines[1]
        set_lines(target, lines)
      end
      return
    end

    render(target, next_state)
  end)
end

local function refresh()
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    load(buffer)
  end
end

local function reset()
  repository.cancel()
  buffer = nil
  directory = nil
  state = nil
end

local function close()
  reset()

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

  directory = vim.fn.getcwd()
  state = nil

  vim.cmd.tabnew()
  buffer = vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_set_name(buffer, "Majjit")
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].filetype = "majjit"
  vim.bo[buffer].swapfile = false
  vim.wo.cursorline = true

  local target = buffer
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = target,
    once = true,
    callback = function()
      if buffer == target then
        reset()
      end
    end,
  })

  set_lines(buffer, { "Loading..." })

  vim.keymap.set("n", "q", close, {
    buffer = buffer,
    desc = "Close Majjit",
  })
  vim.keymap.set("n", "<C-r>", refresh, {
    buffer = buffer,
    desc = "Refresh Majjit",
  })
  vim.keymap.set("n", "<BS>", refresh, {
    buffer = buffer,
    desc = "Refresh Majjit",
  })

  load(buffer)
end

return M
