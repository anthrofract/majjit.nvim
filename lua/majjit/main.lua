local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local HEADER_LINE_COUNT = 2
local FOLD_MARKER_WIDTH = #"▸"
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

local function highlight_log(target, revision_log)
  for _, entry in ipairs(revision_log.entries) do
    if entry.kind == "commit" or entry.kind == "file" then
      local row = entry.line + HEADER_LINE_COUNT - 1
      vim.api.nvim_buf_set_extmark(target, namespace, row, entry.fold_column, {
        end_col = entry.fold_column + FOLD_MARKER_WIDTH,
        hl_group = "Comment",
      })

      if entry.kind == "file" then
        vim.api.nvim_buf_set_extmark(target, namespace, row, entry.content_column, {
          end_col = #entry.lines[1],
          hl_group = "Directory",
        })
      end
    end
  end
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
  elseif entry and entry.kind == "file" then
    selection.change_id = entry.change_id
    selection.path = entry.path
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
      local file = selection.path and log.find_file(next_state.log, selection.change_id, selection.path)
      if file then
        row = file.line + HEADER_LINE_COUNT
      else
        row = commit.line + math.min(selection.offset or 0, #commit.lines - 1) + HEADER_LINE_COUNT
      end
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
  end
  vim.api.nvim_win_set_cursor(window, { row, column })
end

local function render(target, next_state, selection, view)
  if not selection and not view then
    selection, view = capture_selection(target)
  end
  local lines = {
    "repository: " .. next_state.root .. "  revset: " .. next_state.revset,
    "",
  }
  vim.list_extend(lines, next_state.log.lines)
  set_lines(target, lines)
  highlight_header(target, next_state.root, next_state.revset)
  highlight_log(target, next_state.log)
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

local function toggle_fold()
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) or not state then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local commit = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
  if not commit or commit.kind ~= "commit" then
    return
  end

  if commit.loaded then
    local selection, view = capture_selection(buffer)
    commit.expanded = not commit.expanded
    log.flatten(state.log)
    render(buffer, state, selection, view)
    return
  end

  local target = buffer
  local current_state = state
  repository.load_files(state.root, commit, function(files, err)
    if target ~= buffer or current_state ~= state or not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end

    local selection, view = capture_selection(target)
    commit.expanded = true
    commit.files = files
    commit.loaded = true
    log.flatten(state.log)
    render(target, state, selection, view)
  end)
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
  vim.keymap.set("n", "<Tab>", toggle_fold, {
    buffer = buffer,
    desc = "Toggle Majjit fold",
  })
  vim.keymap.set("n", "za", toggle_fold, {
    buffer = buffer,
    desc = "Toggle Majjit fold",
  })

  load(buffer)
end

return M
