local M = {}

local Editor = {}
Editor.__index = Editor

local function append_instructions(contents)
  if contents ~= "" and contents:sub(-1) ~= "\n" then
    contents = contents .. "\n"
  end
  local last_line = contents == "" and "" or contents:sub(1, -2):match("([^\n]*)$")
  contents = contents .. (vim.startswith(last_line, "JJ:") and "JJ:\n" or "\n")
  return contents .. 'JJ: Lines starting with "JJ:" (like this one) will be removed.\n'
end

local function clean_description(lines)
  local description = {}
  for _, line in ipairs(lines) do
    if vim.startswith(line, "JJ: ignore-rest") then
      break
    end
    if not vim.startswith(line, "JJ:") then
      description[#description + 1] = line
    end
  end
  return table.concat(description, "\n"):gsub("^\n+", ""):gsub("\n+$", "")
end

local function description_lines(description)
  local endofline = description:sub(-1) == "\n"
  if endofline then
    description = description:sub(1, -2)
  end
  local lines = vim.split(description, "\n", { plain = true, trimempty = false })
  if #lines == 0 then
    lines = { "" }
  end
  return lines, endofline
end

function M.new(get_source_window)
  return setmetatable({
    buffer = nil,
    get_source_window = get_source_window,
    submitting = false,
    tab = nil,
  }, Editor)
end

function Editor:is_open()
  return self.buffer ~= nil and vim.api.nvim_buf_is_valid(self.buffer)
end

function Editor:focus()
  if not self:is_open() then
    return false
  end
  local windows = vim.fn.win_findbuf(self.buffer)
  if not windows[1] then
    return false
  end
  vim.api.nvim_set_current_win(windows[1])
  return true
end

function Editor:_close_tab(tab)
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) or #vim.api.nvim_list_tabpages() <= 1 then
    return
  end
  local source_window = self.get_source_window()
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd.tabclose({ bang = true })
  if source_window and vim.api.nvim_win_is_valid(source_window) then
    vim.api.nvim_set_current_win(source_window)
  end
end

function Editor:close()
  local buffer = self.buffer
  local tab = self.tab
  self.buffer = nil
  self.submitting = false
  self.tab = nil
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
  self:_close_tab(tab)
end

function Editor:open(opts)
  if self:is_open() then
    self:focus()
    return false
  end

  vim.cmd.tabnew()
  local buffer = vim.api.nvim_get_current_buf()
  self.buffer = buffer
  self.submitting = false
  self.tab = vim.api.nvim_get_current_tabpage()

  local lines, endofline = description_lines(append_instructions(opts.contents))
  vim.api.nvim_buf_set_name(buffer, opts.name or "majjit://describe/" .. opts.change_id)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].endofline = endofline
  vim.bo[buffer].filetype = "jjdescription"
  vim.bo[buffer].modified = false

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buffer,
    callback = function()
      if self.buffer ~= buffer or self.submitting then
        return
      end

      local description = clean_description(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      self.submitting = true
      vim.bo[buffer].modifiable = false

      local source_window = self.get_source_window()
      if source_window and vim.api.nvim_win_is_valid(source_window) then
        vim.api.nvim_set_current_win(source_window)
      end
      opts.on_submit(description, function(succeeded)
        if self.buffer ~= buffer or not vim.api.nvim_buf_is_valid(buffer) then
          return
        end
        if succeeded then
          vim.bo[buffer].modified = false
          self:close()
          return
        end
        self.submitting = false
        vim.bo[buffer].modifiable = true
        self:focus()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      if self.buffer == buffer then
        local tab = self.tab
        self.buffer = nil
        self.submitting = false
        self.tab = nil
        vim.schedule(function()
          self:_close_tab(tab)
        end)
      end
    end,
  })

  if opts.startinsert then
    vim.cmd.startinsert()
  end
  return true
end

return M
