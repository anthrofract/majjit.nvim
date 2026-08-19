local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local active_session
local actions = require("majjit.commands.actions")
local command_catalog = require("majjit.commands.catalog")
local editor_module = require("majjit.commands.editor")
local command_tree = require("majjit.commands.tree").compile(command_catalog)
local command_session = require("majjit.commands.session")
local jj = require("majjit.jj")
local output_module = require("majjit.commands.output")
local prompt_module = require("majjit.commands.prompt")
local view_module = require("majjit.view")
local workflow_module = require("majjit.workflow")

local function reset(session)
  if session.closed then
    return
  end
  session.closed = true
  if session.operation then
    session.operation:cancel()
  end
  if session.commands then
    session.commands:detach()
    session.commands = nil
  end
  if session.editor then
    session.editor:close()
    session.editor = nil
  end
  if session.prompt then
    session.prompt:cancel()
    session.prompt = nil
  end
  if session.output then
    session.output:close()
    session.output = nil
  end
  jj.set_ignore_immutable(false)
  if active_session == session then
    active_session = nil
  end
end

local function close(session)
  reset(session)

  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd.tabclose()
  else
    vim.api.nvim_buf_delete(0, { force = true })
  end
end

function M.open()
  if active_session then
    local buffer = active_session.view.buffer
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      local window = active_session.view:get_window()
      if window then
        vim.api.nvim_set_current_win(window)
        return
      end
    end
    reset(active_session)
  end

  local cwd = vim.fn.getcwd()
  local user_window = vim.api.nvim_get_current_win()

  vim.cmd.tabnew()
  local buffer = vim.api.nvim_get_current_buf()
  local session = {
    closed = false,
    commands = nil,
    cwd = cwd,
    editor = nil,
    operation = nil,
    output = nil,
    prompt = nil,
    user_window = user_window,
    view = view_module.new(buffer, ansi),
  }
  active_session = session

  vim.api.nvim_buf_set_name(buffer, "Majjit")
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].filetype = "majjit"
  vim.bo[buffer].swapfile = false
  vim.wo.cursorline = true
  vim.wo.number = false
  vim.wo.relativenumber = false

  session.output = output_module.new(function()
    return session.view:get_window()
  end, ansi)
  session.editor = editor_module.new(function()
    return session.view:get_window()
  end)
  session.prompt = prompt_module.new({
    can_start = function()
      return not session.closed and session.operation == nil
    end,
    get_buffer = function()
      return not session.closed and session.view.buffer or nil
    end,
    output = session.output,
    update_mappings = function()
      if session.commands then
        session.commands:update_mappings()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      reset(session)
    end,
  })

  session.view:set_lines({ "Loading..." })

  local workflow = workflow_module.new(session)
  session.commands = command_session.attach({
    actions = actions.new(workflow, function()
      close(session)
    end),
    buffer = buffer,
    get_context = function()
      return session.view:get_context()
    end,
    get_window = function()
      return session.view:get_window()
    end,
    overlay = session.output,
    tree = command_tree,
  })

  workflow:load()
end

return M
