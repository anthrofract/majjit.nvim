local M = {}
local fzf_lua = require("fzf-lua")

local Prompt = {}
Prompt.__index = Prompt
local manual_entry = {}

function M.manual_entry(label)
  return setmetatable({ label = label }, manual_entry)
end

function M.new(opts)
  return setmetatable({
    active = nil,
    can_start = opts.can_start,
    get_buffer = opts.get_buffer,
    output = opts.output,
    update_mappings = opts.update_mappings,
  }, Prompt)
end

function Prompt:_begin()
  if self.active then
    vim.notify("A prompt is already open", vim.log.levels.WARN, { title = "Majjit" })
    return
  end
  if self.can_start and not self.can_start() then
    vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
    return
  end

  local request = {
    buffer = self.get_buffer(),
    restore_output = self.output:is_open(),
  }
  self.active = request
  if request.restore_output then
    self.output:hide()
    self.update_mappings()
  end
  return request
end

function Prompt:_can_complete(request)
  if not self.can_start or self.can_start() then
    return true
  end
  self:_restore(request)
  self.active = nil
  vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
  return false
end

function Prompt:_valid(request)
  local buffer = self.get_buffer()
  return self.active == request
    and request.buffer == buffer
    and buffer ~= nil
    and vim.api.nvim_buf_is_valid(buffer)
end

function Prompt:_restore(request)
  if request.restore_output and self:_valid(request) then
    self.output:show()
    self.update_mappings()
  end
end

function Prompt:_error(request, err)
  if self.active ~= request then
    return
  end
  self:_restore(request)
  self.active = nil
  vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Majjit" })
end

function Prompt:_cancel(request)
  if self.active ~= request then
    return
  end
  request.picker_open = false
  self:_restore(request)
  self.active = nil
end

function Prompt:_input(request, opts, callback)
  local ok, input_err = pcall(vim.ui.input, {
    default = opts.default,
    prompt = opts.prompt,
  }, function(value)
    if not self:_valid(request) then
      return
    end
    if value then
      value = vim.trim(value)
    end
    if not value or value == "" then
      self:_restore(request)
      self.active = nil
      return
    end
    if not self:_can_complete(request) then
      return
    end

    self.active = nil
    callback(value)
  end)
  if not ok then
    self:_error(request, input_err)
  end
end

function Prompt:input(opts, callback)
  local request = self:_begin()
  if request then
    self:_input(request, opts, callback)
  end
end

function Prompt:select(opts, callback)
  local request = self:_begin()
  if not request then
    return
  end

  request.process = opts.load(function(items, err)
    if not self:_valid(request) then
      return
    end
    request.process = nil
    if err then
      self:_error(request, err)
      return
    end
    if #items == 0 then
      if opts.allow_custom == false then
        self:_restore(request)
        self.active = nil
        callback(nil, "No candidates available")
        return
      end
      self:_input(request, { prompt = opts.input_prompt or opts.prompt }, callback)
      return
    end

    local format_item = opts.format_item
    for _, item in ipairs(items) do
      if getmetatable(item) == manual_entry then
        format_item = function(value)
          if getmetatable(value) == manual_entry then
            return value.label
          end
          return opts.format_item and opts.format_item(value) or tostring(value)
        end
        break
      end
    end
    local entries = {}
    for index, item in ipairs(items) do
      entries[index] = string.format("%d\t%s", index, format_item and format_item(item) or tostring(item))
    end

    local function cancel()
      if not self:_valid(request) then
        return
      end
      self:_cancel(request)
    end

    local function select(selected)
      if not self:_valid(request) then
        return
      end
      request.picker_open = false
      local index = selected and selected[1] and tonumber(selected[1]:match("^(%d+)\t"))
      local selected_item = index and items[index]
      if not selected_item then
        self:_error(request, "fzf-lua returned an invalid selection")
        return
      end
      if getmetatable(selected_item) == manual_entry then
        self:_input(request, { prompt = opts.input_prompt or opts.prompt }, callback)
        return
      end
      if not self:_can_complete(request) then
        return
      end

      self.active = nil
      callback(selected_item)
    end

    request.picker_open = true
    local ok, select_err = pcall(fzf_lua.fzf_exec, entries, {
      actions = {
        ["default"] = select,
        ["esc"] = cancel,
        ["ctrl-c"] = cancel,
        ["ctrl-q"] = cancel,
      },
      fzf_opts = {
        ["--delimiter"] = "\t",
        ["--no-multi"] = "",
        ["--with-nth"] = "2..",
      },
      fzf_colors = true,
      hls = {
        border = "MajjitDecoration",
        fzf = {
          separator = "MajjitDecoration",
        },
      },
      profile = "ivy",
      prompt = opts.prompt:gsub(":%s*$", "") .. " > ",
      winopts = {
        border = { "─", "─", "─", "", "", "", "", "" },
        height = 0.3,
        on_close = function()
          vim.schedule(function()
            if self:_valid(request) and request.picker_open then
              self:_cancel(request)
            end
          end)
        end,
        on_create = function(event)
          request.picker_buffer = event.bufnr
        end,
      },
    })
    if not ok then
      self:_error(request, select_err)
    end
  end)
end

function Prompt:preserve_output()
  if self.active then
    self.active.restore_output = true
  end
end

function Prompt:cancel()
  local request = self.active
  self.active = nil
  if request and request.process then
    pcall(request.process.kill, request.process, 15)
  end
  if request and request.picker_buffer then
    pcall(fzf_lua.win.close, request.picker_buffer)
  end
end

return M
