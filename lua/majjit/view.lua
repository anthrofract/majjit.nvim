local log = require("majjit.log")

local M = {}

local HEADER_LINE_COUNT = 2
local FOLD_MARKER_WIDTH = #"▸"

local View = {}
View.__index = View

local function highlight_header(view, revset)
  local revset_label = "revset: "
  local revset_start = #revset_label

  vim.api.nvim_buf_set_extmark(view.buffer, view.namespace, 0, 0, {
    end_col = revset_start,
    hl_group = "MajjitLabel",
  })
  vim.api.nvim_buf_set_extmark(view.buffer, view.namespace, 0, revset_start, {
    end_col = revset_start + #revset,
    hl_group = "MajjitValue",
  })
  if view.ignore_immutable then
    local option_start = revset_start + #revset + 2
    vim.api.nvim_buf_set_extmark(view.buffer, view.namespace, 0, option_start, {
      end_col = option_start + #"--ignore-immutable",
      hl_group = "MajjitAnsiRed",
    })
  end
end

local function highlight_log(view, revision_log)
  for _, entry in ipairs(revision_log.entries) do
    if entry.kind == "commit" or entry.kind == "file" or entry.kind == "hunk" then
      local row = entry.line + HEADER_LINE_COUNT - 1
      vim.api.nvim_buf_set_extmark(view.buffer, view.namespace, row, entry.fold_column, {
        end_col = entry.fold_column + FOLD_MARKER_WIDTH,
        hl_group = "MajjitDecoration",
      })

      if entry.kind == "file" then
        local line = vim.api.nvim_buf_get_lines(view.buffer, row, row + 1, false)[1]
        vim.api.nvim_buf_set_extmark(view.buffer, view.namespace, row, entry.content_column, {
          end_col = #line,
          hl_group = "MajjitFile",
        })
      end
    end
  end
end

local function highlight_source(view, revision_log)
  if not view.source or not view.source.commit then
    return
  end

  local entries = { log.find_commit(revision_log, view.source.commit.change_id) }
  if view.source.file then
    entries[#entries + 1] = log.find_file(revision_log, view.source.commit.change_id, view.source.file.path)
  end
  for _, entry in ipairs(entries) do
    if entry then
      view.source_extmarks[#view.source_extmarks + 1] = vim.api.nvim_buf_set_extmark(
        view.buffer,
        view.namespace,
        entry.line + HEADER_LINE_COUNT - 1,
        0,
        { line_hl_group = "MajjitSelection" }
      )
    end
  end
end

local function restore_selection(view, next_state, selection, saved_view)
  local windows = vim.fn.win_findbuf(view.buffer)
  if not windows[1] then
    return
  end

  local row
  if selection and selection.change_id then
    local commit = log.find_commit(next_state.log, selection.change_id)
    if commit then
      local file = selection.path and log.find_file(next_state.log, selection.change_id, selection.path)
      if not file then
        row = commit.line + math.min(selection.offset or 0, #commit.lines - 1) + HEADER_LINE_COUNT
      elseif selection.hunk_index then
        local hunk = log.find_hunk(next_state.log, selection.change_id, selection.path, selection.hunk_index)
        local diff_line = selection.line_index
          and log.find_diff_line(
            next_state.log,
            selection.change_id,
            selection.path,
            selection.hunk_index,
            selection.line_index
          )
        row = (diff_line and diff_line.line or hunk and hunk.line or file.line) + HEADER_LINE_COUNT
      else
        row = file.line + HEADER_LINE_COUNT
      end
    end
  elseif selection then
    row = selection.row
  end
  row = row or (next_state.log.current_line and next_state.log.current_line + HEADER_LINE_COUNT)
  row = math.max(1, math.min(row or 1, vim.api.nvim_buf_line_count(view.buffer)))

  local line = vim.api.nvim_buf_get_lines(view.buffer, row - 1, row, false)[1]
  local column = math.min(selection and selection.column or 0, #line)
  local window = windows[1]
  if saved_view then
    saved_view.lnum = row
    saved_view.col = column
    vim.api.nvim_win_call(window, function()
      vim.fn.winrestview(saved_view)
    end)
  end
  vim.api.nvim_win_set_cursor(window, { row, column })
end

function M.new(buffer, ansi)
  return setmetatable({
    ansi = ansi,
    buffer = buffer,
    cursor_namespace = vim.api.nvim_create_namespace("majjit-cursor"),
    ignore_immutable = false,
    namespace = vim.api.nvim_create_namespace("majjit"),
    source = nil,
    source_extmarks = {},
    state = nil,
  }, View)
end

function View:get_window()
  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == self.buffer then
    return current
  end
  return vim.fn.win_findbuf(self.buffer)[1]
end

function View:set_lines(lines)
  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.buffer, self.namespace, 0, -1)
  self.source_extmarks = {}
  self.ansi.once(self.buffer)
  vim.bo[self.buffer].modifiable = false
end

function View:get_context()
  local context = {
    capabilities = {
      repository = self.state ~= nil,
    },
    revset = self.state and self.state.revset,
    root = self.state and self.state.root,
  }
  local window = self:get_window()
  if not self.state or not window then
    return context
  end

  local entry = self:entry_at_cursor(window)
  local file = log.file_for_entry(self.state.log, entry)
  context.commit = log.commit_for_entry(self.state.log, entry)
  context.file = file
  context.capabilities.commit = context.commit ~= nil
  context.capabilities.file = file ~= nil
  context.capabilities.foldable = entry ~= nil
    and (entry.kind == "commit" or entry.kind == "file" or entry.kind == "hunk")
  return context
end

function View:entry_at_cursor(window)
  if not self.state then
    return
  end
  window = window or self:get_window()
  if not window then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  return log.entry_at_line(self.state.log, cursor[1] - HEADER_LINE_COUNT)
end

function View:highlight_cursor(window)
  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buffer, self.cursor_namespace, 0, -1)

  window = window or self:get_window()
  if not self.state or not window then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local entry = log.entry_at_line(self.state.log, cursor[1] - HEADER_LINE_COUNT)
  if not entry then
    return
  end

  local first_row = cursor[1] - 1
  local line_count = 1
  if entry.kind == "commit" and #entry.lines == 2 then
    first_row = entry.line + HEADER_LINE_COUNT - 1
    line_count = 2
  end
  for row = first_row, first_row + line_count - 1 do
    vim.api.nvim_buf_set_extmark(self.buffer, self.cursor_namespace, row, 0, {
      line_hl_group = "MajjitCursorLine",
      priority = 200,
    })
  end
end

function View:move_item(direction, count, window)
  window = window or self:get_window()
  if not self.state or not window then
    return false
  end

  count = math.max(1, count or 1)
  local cursor = vim.api.nvim_win_get_cursor(window)
  local _, _, index = log.entry_at_line(self.state.log, cursor[1] - HEADER_LINE_COUNT)
  if not index then
    vim.api.nvim_win_call(window, function()
      vim.cmd(("normal! %d%s"):format(count, direction > 0 and "j" or "k"))
    end)
    self:highlight_cursor(window)
    return true
  end

  local entries = self.state.log.entries
  local target_index = math.max(1, math.min(index + direction * count, #entries))
  if target_index == index then
    self:highlight_cursor(window)
    return true
  end
  local row = entries[target_index].line + HEADER_LINE_COUNT
  local line = vim.api.nvim_buf_get_lines(self.buffer, row - 1, row, false)[1]
  vim.api.nvim_win_set_cursor(window, { row, math.min(cursor[2], #line) })
  self:highlight_cursor(window)
  return true
end

function View:focus_commit(change_id)
  local commit = self.state and log.find_commit(self.state.log, change_id)
  if not commit then
    return false
  end
  return self:focus_log_line(commit.line)
end

function View:focus_log_line(line)
  local window = self:get_window()
  if not window then
    return false
  end
  vim.api.nvim_win_set_cursor(window, { line + HEADER_LINE_COUNT, 0 })
  self:highlight_cursor(window)
  return true
end

function View:capture_selection()
  if not self.state then
    return nil, nil
  end

  local windows = vim.fn.win_findbuf(self.buffer)
  if not windows[1] then
    return nil, nil
  end

  local window = windows[1]
  local cursor = vim.api.nvim_win_get_cursor(window)
  local selection = {
    column = cursor[2],
    row = cursor[1],
  }
  local entry, offset = log.entry_at_line(self.state.log, cursor[1] - HEADER_LINE_COUNT)
  if entry and entry.kind == "commit" then
    selection.change_id = entry.change_id
    selection.offset = offset
  elseif entry and entry.kind == "file" then
    selection.change_id = entry.change_id
    selection.path = entry.path
  elseif entry and entry.kind == "hunk" then
    selection.change_id = entry.change_id
    selection.hunk_index = entry.index
    selection.path = entry.path
  elseif entry and entry.kind == "diff_line" then
    selection.change_id = entry.change_id
    selection.hunk_index = entry.hunk_index
    selection.line_index = entry.index
    selection.path = entry.path
  end

  local saved_view = vim.api.nvim_win_call(window, vim.fn.winsaveview)
  return selection, saved_view
end

function View:render(next_state, selection, saved_view)
  if not selection and not saved_view then
    selection, saved_view = self:capture_selection()
  end
  local lines = {
    "revset: " .. next_state.revset .. (self.ignore_immutable and "  --ignore-immutable" or ""),
    "",
  }
  vim.list_extend(lines, next_state.log.lines)
  self:set_lines(lines)
  highlight_header(self, next_state.revset)
  highlight_log(self, next_state.log)
  highlight_source(self, next_state.log)
  self.state = next_state
  restore_selection(self, next_state, selection, saved_view)
  self:highlight_cursor()
end

function View:set_source(source)
  self.source = vim.deepcopy(source)
  for _, extmark in ipairs(self.source_extmarks) do
    pcall(vim.api.nvim_buf_del_extmark, self.buffer, self.namespace, extmark)
  end
  self.source_extmarks = {}
  if self.state then
    highlight_source(self, self.state.log)
  end
end

function View:clear_source()
  self.source = nil
  for _, extmark in ipairs(self.source_extmarks) do
    pcall(vim.api.nvim_buf_del_extmark, self.buffer, self.namespace, extmark)
  end
  self.source_extmarks = {}
end

function View:set_ignore_immutable(enabled)
  self.ignore_immutable = enabled
  if self.state then
    self:render(self.state)
  end
end

return M
