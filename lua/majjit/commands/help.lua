local M = {}

local Help = {}
Help.__index = Help

local COLUMN_GAP = 3
local MAX_ENTRIES_PER_COLUMN = 17

local function group_entries(entries)
  local groups = {}
  local by_name = {}
  for _, entry in ipairs(entries) do
    local group = by_name[entry.group]
    if not group then
      group = { balance = entry.balance, name = entry.group, entries = {} }
      by_name[entry.group] = group
      groups[#groups + 1] = group
    end
    group.entries[#group.entries + 1] = entry
  end
  return groups
end

local function entry_cell(entry)
  local keys = table.concat(entry.keys, "/")
  local text = keys .. " " .. entry.label
  return {
    text = text,
    highlights = {
      { group = "MajjitValue", start = 0, finish = #keys },
    },
  }
end

local function build_columns(entries)
  local columns = {}
  for _, group in ipairs(group_entries(entries)) do
    local column_count = math.ceil(#group.entries / MAX_ENTRIES_PER_COLUMN)
    local column_size = group.balance and math.ceil(#group.entries / column_count) or MAX_ENTRIES_PER_COLUMN
    for start = 1, #group.entries, column_size do
      local column = {
        rows = {
          {
            text = start == 1 and group.name or "",
            highlights = start == 1 and {
              { group = "MajjitLabel", start = 0, finish = #group.name },
            } or {},
          },
        },
        width = 0,
      }
      local finish = math.min(start + column_size - 1, #group.entries)
      for i = start, finish do
        column.rows[#column.rows + 1] = entry_cell(group.entries[i])
      end
      for _, row in ipairs(column.rows) do
        column.width = math.max(column.width, vim.fn.strdisplaywidth(row.text))
      end
      columns[#columns + 1] = column
    end
  end
  return columns
end

local function render(entries, error_message)
  local lines = {}
  local highlights = {}
  local columns = build_columns(entries)
  local row_count = 0
  for _, column in ipairs(columns) do
    row_count = math.max(row_count, #column.rows)
  end

  for row_index = 1, row_count do
    local line = " "
    for column_index, column in ipairs(columns) do
      local cell = column.rows[row_index] or { text = "", highlights = {} }
      local cell_start = #line
      line = line .. cell.text
      for _, highlight in ipairs(cell.highlights) do
        highlights[#highlights + 1] = {
          group = highlight.group,
          line = row_index - 1,
          start = cell_start + highlight.start,
          finish = cell_start + highlight.finish,
        }
      end

      local padding = column.width - vim.fn.strdisplaywidth(cell.text)
      line = line .. string.rep(" ", padding)
      if column_index < #columns then
        line = line .. string.rep(" ", COLUMN_GAP)
      end
    end
    lines[#lines + 1] = line
  end

  if error_message then
    lines[#lines + 1] = ""
    lines[#lines + 1] = error_message
    highlights[#highlights + 1] = {
      group = "MajjitAnsiRed",
      line = #lines - 1,
      start = 0,
      finish = #error_message,
    }
  end
  if #lines == 0 then
    lines = { " No commands available" }
  end
  lines[#lines + 1] = ""
  return lines, highlights
end

function M.new(get_source_window)
  return setmetatable({
    buffer = nil,
    get_source_window = get_source_window,
    namespace = vim.api.nvim_create_namespace("majjit-commands-help"),
    window = nil,
  }, Help)
end

function Help:is_open()
  return self.window ~= nil and vim.api.nvim_win_is_valid(self.window)
end

function Help:close()
  if self:is_open() then
    vim.api.nvim_win_close(self.window, true)
  end
  if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
  self.buffer = nil
  self.window = nil
end

function Help:show(entries, error_message)
  local source_window = self.get_source_window()
  if not source_window or not vim.api.nvim_win_is_valid(source_window) then
    self:close()
    return false
  end

  local lines, highlights = render(entries, error_message)
  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  local height = math.min(#lines, math.max(1, bottom - 1))
  local config = {
    anchor = "SW",
    border = { "─", "─", "─", "", "", "", "", "" },
    col = 0,
    focusable = false,
    height = height,
    relative = "editor",
    row = bottom,
    style = "minimal",
    width = vim.o.columns,
    zindex = 50,
  }

  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
    self.buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[self.buffer].bufhidden = "wipe"
    vim.bo[self.buffer].filetype = "majjit-help"
    vim.bo[self.buffer].swapfile = false
  end

  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.buffer, self.namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(self.buffer, self.namespace, highlight.line, highlight.start, {
      end_col = highlight.finish,
      hl_group = highlight.group,
    })
  end
  vim.bo[self.buffer].modifiable = false

  if self:is_open() then
    vim.api.nvim_win_set_config(self.window, config)
  else
    self.window = vim.api.nvim_open_win(self.buffer, false, config)
    vim.wo[self.window].winhighlight = "NormalFloat:MajjitNormal,FloatBorder:MajjitDecoration"
  end
  return true
end

return M
