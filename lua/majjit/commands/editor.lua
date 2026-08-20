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
    source_buffer = nil,
    submitting = false,
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

function Editor:close()
  local buffer = self.buffer
  local source_buffer = self.source_buffer
  self.buffer = nil
  self.source_buffer = nil
  self.submitting = false
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    local window = vim.fn.win_findbuf(buffer)[1]
    if window and source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
      vim.api.nvim_win_set_buf(window, source_buffer)
    else
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  if source_buffer and vim.api.nvim_buf_is_valid(source_buffer) then
    vim.bo[source_buffer].bufhidden = "wipe"
  end
end

function Editor:open(opts)
  if self:is_open() then
    self:focus()
    return false
  end

  local window = self.get_source_window()
  local source_buffer = vim.api.nvim_win_get_buf(window)
  local buffer = vim.api.nvim_create_buf(true, false)
  self.buffer = buffer
  self.source_buffer = source_buffer
  self.submitting = false
  vim.bo[source_buffer].bufhidden = "hide"

  local lines, endofline = description_lines(append_instructions(opts.contents))
  vim.api.nvim_buf_set_name(buffer, opts.name or "majjit://describe/" .. opts.change_id)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].endofline = endofline
  vim.bo[buffer].filetype = "jjdescription"
  vim.bo[buffer].modified = false
  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_set_current_win(window)
  vim.keymap.set("n", "ZZ", "<Cmd>write<CR>", { buffer = buffer, desc = "Save Majjit description" })
  vim.keymap.set("n", "ZQ", function()
    self:close()
  end, { buffer = buffer, desc = "Discard Majjit description" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buffer,
    callback = function()
      if self.buffer ~= buffer or self.submitting then
        return
      end

      local description = clean_description(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      self.submitting = true
      vim.bo[buffer].modifiable = false

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
        self.buffer = nil
        self.source_buffer = nil
        self.submitting = false
      end
    end,
  })

  if opts.startinsert then
    vim.cmd.startinsert()
  end
  return true
end

return M
