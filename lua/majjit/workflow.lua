local jj = require("majjit.jj")
local jump = require("majjit.jump")
local log = require("majjit.log")
local operation_module = require("majjit.operation")
local repository = require("majjit.repository")

local M = {}

local Workflow = {}
Workflow.__index = Workflow

local function mutation_error(result)
  local message = result.error
  if not message or message == "" then
    message = result.stderr
  end
  if not message or message == "" then
    message = "jj exited with code " .. tostring(result.code)
  end
  return message
end

local function command_succeeded(result)
  return not result.error and result.code == 0
end

function M.new(session)
  return setmetatable({ session = session }, Workflow)
end

function Workflow:_render(state, selection, saved_view)
  local session = self.session
  session.view:render(state, selection, saved_view)
  if session.commands then
    session.commands:update_help()
  end
end

function Workflow:_start_operation(fn, callback)
  local session = self.session
  if session.closed then
    return
  end
  if session.operation then
    vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
    return
  end

  local operation
  local completed = false
  operation = operation_module.new(fn, function(value, err)
    completed = true
    if session.operation == operation then
      session.operation = nil
    end
    if not session.closed then
      callback(value, err)
    end
  end)
  operation.on_cancel = function()
    if session.operation == operation then
      session.operation = nil
    end
  end
  if not completed and not operation.cancelled then
    session.operation = operation
  end
  return operation
end

function Workflow:_run_command(operation, repository_path, command, show_output)
  local session = self.session
  if not session.output:has_output() then
    session.output:start_sequence(show_output)
  elseif show_output then
    session.output:show()
  end
  session.output:start_command(command, show_output)
  if session.commands then
    session.commands:update_mappings()
  end
  local result = operation:await(function(callback)
    return jj.run_mutation(repository_path, command, callback)
  end)
  session.output:finish_command(result)
  return result
end

function Workflow:_repair_workspace(operation, repository_path, show_output)
  return self:_run_command(operation, repository_path, jj.workspace_update_stale(), show_output)
end

function Workflow:_load_repository(operation, repository_path, show_recovery, allow_recovery)
  local next_state, err = repository.load(operation, repository_path)
  if not err or allow_recovery == false or not jj.is_stale_error(err) then
    return next_state, err
  end

  local result = self:_repair_workspace(operation, repository_path, show_recovery)
  if not command_succeeded(result) then
    return nil, mutation_error(result)
  end
  return repository.load(operation, repository_path)
end

function Workflow:_load_with_recovery(operation, state, target, intent, resolve, load)
  local value, err = load(operation, state, target)
  if not err then
    return {
      recovered = false,
      state = state,
      target = target,
      value = value,
    }
  end
  if not jj.is_stale_error(err) then
    return { state = nil }, err
  end

  local recovery = self:_repair_workspace(operation, state.root, true)
  if not command_succeeded(recovery) then
    return nil, mutation_error(recovery)
  end

  state, err = repository.load(operation, state.root)
  if err then
    return nil, err
  end
  target = resolve(state, intent)
  if not target then
    return { state = state }, "Selection no longer exists after recovering the workspace"
  end

  value, err = load(operation, state, target)
  if err then
    return { state = state }, err
  end
  return {
    recovered = true,
    state = state,
    target = target,
    value = value,
  }
end

function Workflow:_show_load_error(err)
  local session = self.session
  if session.view.state then
    vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
  else
    local lines = vim.split(err, "\n", { plain = true })
    lines[1] = "Error: " .. lines[1]
    session.view:set_lines(lines)
  end
end

function Workflow:load(selection)
  local session = self.session
  local repository_path = session.view.state and session.view.state.root or session.cwd
  local target = session.view.buffer
  return self:_start_operation(function(operation)
    return self:_load_repository(operation, repository_path, true, true)
  end, function(next_state, err)
    if target ~= session.view.buffer or not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if err then
      self:_show_load_error(err)
      return
    end
    self:_render(next_state, selection)
  end)
end

function Workflow:refresh()
  local session = self.session
  if not session.operation and vim.api.nvim_buf_is_valid(session.view.buffer) then
    self:load()
  end
end

local function resolve_entry(repository_state, intent)
  if intent.kind == "commit" then
    return log.find_commit(repository_state.log, intent.change_id)
  end
  return log.find_file(repository_state.log, intent.change_id, intent.path)
end

local function load_children(operation, repository_state, entry)
  if entry.kind == "commit" then
    return repository.load_files(operation, repository_state.root, entry)
  end
  return repository.load_hunks(operation, repository_state.root, entry)
end

function Workflow:toggle_fold(window)
  local session = self.session
  local state = session.view.state
  local buffer = session.view.buffer
  if session.operation or not vim.api.nvim_buf_is_valid(buffer) or not state then
    return
  end

  local entry = session.view:entry_at_cursor(window or 0)
  if not entry or entry.kind == "diff_line" or entry.kind == "text" then
    return
  end

  if entry.kind == "hunk" or entry.loaded then
    local selection, saved_view = session.view:capture_selection()
    entry.expanded = not entry.expanded
    log.flatten(state.log)
    self:_render(state, selection, saved_view)
    return
  end

  local selection, saved_view = session.view:capture_selection()
  local intent = {
    change_id = entry.change_id,
    kind = entry.kind,
    path = entry.path,
  }
  local initial_state = state
  self:_start_operation(function(operation)
    return self:_load_with_recovery(operation, initial_state, entry, intent, resolve_entry, load_children)
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      if result and result.state then
        self:_render(result.state, selection, saved_view)
      end
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    result.target.expanded = true
    result.target.loaded = true
    if result.target.kind == "commit" then
      result.target.files = result.value
    else
      result.target.hunks = result.value
    end
    log.flatten(result.state.log)
    if not result.recovered then
      selection, saved_view = session.view:capture_selection()
    end
    self:_render(result.state, selection, saved_view)
  end)
end

function Workflow:right_click()
  local session = self.session
  local buffer = session.view.buffer
  local mouse = vim.fn.getmousepos()
  if
    mouse.winid == 0
    or mouse.line == 0
    or not vim.api.nvim_win_is_valid(mouse.winid)
    or vim.api.nvim_win_get_buf(mouse.winid) ~= buffer
    or mouse.line > vim.api.nvim_buf_line_count(buffer)
  then
    return
  end

  local line = vim.api.nvim_buf_get_lines(buffer, mouse.line - 1, mouse.line, false)[1]
  local column = math.min(math.max(mouse.column - 1, 0), #line)
  vim.api.nvim_set_current_win(mouse.winid)
  vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, column })
  self:toggle_fold(mouse.winid)
end

function Workflow:open_file()
  local session = self.session
  local state = session.view.state
  local buffer = session.view.buffer
  if session.operation or not vim.api.nvim_buf_is_valid(buffer) or not state then
    return
  end

  local entry = session.view:entry_at_cursor(0)
  local file = log.file_for_entry(state.log, entry)
  if not file then
    return
  end

  local commit = log.find_commit(state.log, file.change_id)
  if not commit then
    return
  end

  if commit.current_working_copy then
    local _, err = jump.open_working_file(state.root, file.path, session.user_window, buffer)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
    end
    return
  end

  if jump.focus_historical_file(commit.commit_id, file.path) then
    return
  end

  local selection, saved_view = session.view:capture_selection()
  local initial_state = state
  local intent = {
    change_id = file.change_id,
    path = file.path,
  }
  self:_start_operation(function(operation)
    return self:_load_with_recovery(
      operation,
      initial_state,
      commit,
      intent,
      function(repository_state, selection)
        return log.find_commit(repository_state.log, selection.change_id)
      end,
      function(active_operation, repository_state)
        return repository.load_file(active_operation, repository_state.root, intent.change_id, intent.path)
      end
    )
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      if result and result.state then
        self:_render(result.state, selection, saved_view)
      end
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    if result.state ~= session.view.state then
      self:_render(result.state, selection, saved_view)
    end
    local _, open_err = jump.open_historical_file(result.target.commit_id, intent.path, result.value)
    if open_err then
      vim.notify(open_err, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

function Workflow:mutate(context, command_list, select_current, append_output)
  local session = self.session
  if type(command_list[1]) == "string" then
    command_list = { command_list }
  end
  local repository_path = context.root or session.cwd
  local buffer = session.view.buffer
  local selection = select_current and {} or nil
  return self:_start_operation(function(operation)
    if append_output and session.output:has_output() then
      session.output:show()
    else
      session.output:start_sequence()
    end
    local changed = false
    for _, command in ipairs(command_list) do
      local result = self:_run_command(operation, repository_path, command, true)
      if not command_succeeded(result) and jj.is_stale_error(result) then
        local recovery = self:_repair_workspace(operation, repository_path, true)
        if not command_succeeded(recovery) then
          return { failure = recovery }
        end
        changed = true
        result = self:_run_command(operation, repository_path, command, true)
      end
      if not command_succeeded(result) then
        local next_state
        if changed then
          next_state = self:_load_repository(operation, repository_path, true, false)
        end
        return { failure = result, state = next_state }
      end
      changed = true
    end
    local next_state, err = self:_load_repository(operation, repository_path, true, true)
    if err then
      return nil, err
    end
    return { state = next_state }
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    if result.state then
      self:_render(result.state, selection)
    end
    if result.failure and not session.output:is_open() then
      local message = vim.trim(mutation_error(result.failure):gsub("\27%[[0-9;]*m", ""))
      vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

function Workflow:_select_repository_value(root, prompt, query, callback)
  local session = self.session
  local append_output = false
  session.prompt:select({
    load = function(on_load)
      return self:_start_operation(function(operation)
        local items, err = operation:await(query)
        local next_state
        if err and jj.is_stale_error(err) then
          append_output = true
          local recovery = self:_repair_workspace(operation, root, false)
          if not command_succeeded(recovery) then
            return { recovered = true }, mutation_error(recovery)
          end
          next_state, err = repository.load(operation, root)
          if err then
            return { recovered = true }, err
          end
          items, err = operation:await(query)
        end
        if err then
          return { recovered = append_output, state = next_state }, err
        end
        return { items = items, recovered = append_output, state = next_state }
      end, function(result, err)
        if result and result.recovered then
          session.prompt:preserve_output()
        end
        if err then
          if result and result.state and vim.api.nvim_buf_is_valid(session.view.buffer) then
            self:_render(result.state)
          end
          on_load(nil, err)
          return
        end
        if result.state and vim.api.nvim_buf_is_valid(session.view.buffer) then
          self:_render(result.state)
        end
        on_load(result.items, nil)
      end)
    end,
    prompt = prompt,
  }, function(value)
    callback(value, append_output)
  end)
end

function Workflow:select_revision_target(context, prompt, callback)
  local root = context.root
  local revset = context.revset
  self:_select_repository_value(root, prompt, function(on_load)
    return jj.revision_targets(root, revset, on_load)
  end, callback)
end

function Workflow:select_visible_commit(kind)
  local session = self.session
  local state = session.view.state
  if not state then
    return
  end

  local candidates = log.selection_candidates(state.log, kind)
  if #candidates == 0 then
    return
  end
  session.prompt:select({
    format_item = function(candidate)
      return candidate.label
    end,
    load = function(callback)
      callback(candidates, nil)
    end,
    prompt = "Select: ",
  }, function(candidate)
    if session.view.state ~= state or not session.view:focus_commit(candidate.change_id) then
      vim.notify("Selection is no longer visible", vim.log.levels.WARN, { title = "Majjit" })
    end
  end)
end

function Workflow:input(prompt, callback)
  self.session.prompt:input({ prompt = prompt }, callback)
end

function Workflow:input_revset(context)
  local root = context.root
  self:input("Revsets: ", function(value)
    self:mutate({ root = root }, jj.new_revision(value, {}), true)
  end)
end

function Workflow:select_bookmark(root, prompt, callback)
  self:_select_repository_value(root, prompt, function(on_load)
    return jj.bookmark_names(root, on_load)
  end, callback)
end

function Workflow:select_git_remote(root, callback)
  self:_select_repository_value(root, "Fetch remote: ", function(on_load)
    return jj.git_remote_names(root, on_load)
  end, callback)
end

function Workflow:toggle_ignore_immutable()
  local view = self.session.view
  local enabled = not view.ignore_immutable
  jj.set_ignore_immutable(enabled)
  view:set_ignore_immutable(enabled)
end

return M
