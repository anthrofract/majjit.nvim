local M = {}

local Output = {}
Output.__index = Output

local function append_text(lines, text)
  text = text:gsub("[\r\n]+$", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then
    return false
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return true
end

function M.new(get_source_window, ansi)
  return setmetatable({
    ansi = ansi,
    buffer = nil,
    completed = false,
    get_source_window = get_source_window,
    heading_lines = {},
    lines = {},
    namespace = vim.api.nvim_create_namespace("majjit-commands-output"),
    window = nil,
  }, Output)
end

function Output:is_open()
  return self.window ~= nil and vim.api.nvim_win_is_valid(self.window)
end

function Output:has_output()
  return #self.lines > 0
end

function Output:_ensure_buffer()
  if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buffer].bufhidden = "hide"
  vim.bo[self.buffer].buftype = "nofile"
  vim.bo[self.buffer].filetype = "majjit-output"
  vim.bo[self.buffer].swapfile = false
end

function Output:_render(open)
  self:_ensure_buffer()

  local rendered = vim.deepcopy(self.lines)
  rendered[#rendered + 1] = ""
  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, rendered)
  vim.api.nvim_buf_clear_namespace(self.buffer, self.namespace, 0, -1)
  self.ansi.once(self.buffer)
  for line in pairs(self.heading_lines) do
    vim.api.nvim_buf_set_extmark(self.buffer, self.namespace, line - 1, 0, {
      end_col = #"❯",
      hl_group = "DiagnosticWarn",
    })
  end
  vim.bo[self.buffer].modifiable = false

  if not open and not self:is_open() then
    return true
  end
  local source_window = self.get_source_window()
  if not source_window or not vim.api.nvim_win_is_valid(source_window) then
    self:hide()
    return false
  end

  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  local config = {
    anchor = "SW",
    border = { "─", "─", "─", "", "", "", "", "" },
    col = 0,
    focusable = false,
    height = math.min(#rendered, math.max(1, bottom - 1)),
    relative = "editor",
    row = bottom,
    style = "minimal",
    width = vim.o.columns,
    zindex = 40,
  }
  if self:is_open() then
    vim.api.nvim_win_set_config(self.window, config)
  else
    self.window = vim.api.nvim_open_win(self.buffer, false, config)
    vim.wo[self.window].winhighlight = "NormalFloat:Normal,FloatBorder:Comment"
  end
  vim.api.nvim_win_set_cursor(self.window, { #rendered, 0 })
  return true
end

function Output:start_sequence(show)
  self.completed = false
  self.heading_lines = {}
  self.lines = {}
  self:_render(show ~= false)
end

function Output:start_command(command, show)
  local display_command = command.display or command.display_args or command.args or command
  if self.completed then
    self.lines[#self.lines + 1] = ""
  end
  self.lines[#self.lines + 1] = "❯ jj " .. table.concat(display_command, " ")
  self.heading_lines[#self.lines] = true
  self.lines[#self.lines + 1] = ""
  self.lines[#self.lines + 1] = "Running..."
  self.completed = false
  self:_render(show ~= false)
end

function Output:finish_command(result)
  if self.lines[#self.lines] == "Running..." then
    self.lines[#self.lines] = nil
  end

  local has_result_output = result.stdout and append_text(self.lines, result.stdout)
  if result.stderr and append_text(self.lines, result.stderr) then
    has_result_output = true
  end
  if not has_result_output and result.error then
    append_text(self.lines, result.error)
  elseif not has_result_output and result.code ~= 0 then
    self.lines[#self.lines + 1] = "jj exited with code " .. result.code
  end
  self.completed = true
  self:_render(self:is_open())
end

function Output:hide()
  if self:is_open() then
    vim.api.nvim_win_close(self.window, true)
  end
  self.window = nil
end

function Output:show()
  if not self:has_output() then
    return false
  end
  return self:_render(true)
end

function Output:close()
  self:hide()
  if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
  self.buffer = nil
  self.completed = false
  self.heading_lines = {}
  self.lines = {}
end

return M
