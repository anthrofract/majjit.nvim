local jj = require("majjit.jj")
local jump = require("majjit.jump")
local log = require("majjit.log")
local operation_module = require("majjit.operation")
local prompt_module = require("majjit.commands.prompt")
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
  session.revset = session.revset or repository.DEFAULT_REVSET
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

function Workflow:_load_repository(operation, repository_path, show_recovery, allow_recovery, revset)
  revset = revset or self.session.revset
  local next_state, err = repository.load(operation, repository_path, revset)
  if not err or allow_recovery == false or not jj.is_stale_error(err) then
    return next_state, err
  end

  local result = self:_repair_workspace(operation, repository_path, show_recovery)
  if not command_succeeded(result) then
    return nil, mutation_error(result)
  end
  return repository.load(operation, repository_path, revset)
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

  state, err = repository.load(operation, state.root, self.session.revset)
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
    session.revset = next_state.revset
  end)
end

function Workflow:move_item(direction, count)
  return self.session.view:move_item(direction, count)
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
    local _, err = jump.open_working_file(state.root, file.path, buffer)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
    end
    return
  end

  if jump.focus_historical_file(commit.commit_id, file.path, buffer) then
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
    local _, open_err = jump.open_historical_file(
      result.target.commit_id,
      intent.path,
      result.value,
      buffer
    )
    if open_err then
      vim.notify(open_err, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

function Workflow:mutate(context, command_list, select_current, append_output, on_complete)
  local session = self.session
  if command_list.args or type(command_list[1]) == "string" then
    command_list = { command_list }
  end
  local repository_path = context.root or session.cwd
  local buffer = session.view.buffer
  local selection = type(select_current) == "table" and select_current or select_current and {} or nil
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
          return { failure = recovery, succeeded = false }
        end
        changed = true
        result = self:_run_command(operation, repository_path, command, true)
      end
      if not command_succeeded(result) then
        local next_state
        if changed then
          next_state = self:_load_repository(operation, repository_path, true, false)
        end
        return { failure = result, state = next_state, succeeded = false }
      end
      changed = true
    end
    local next_state, err = self:_load_repository(operation, repository_path, true, true)
    if err then
      return { succeeded = true }, err
    end
    return { state = next_state, succeeded = true }
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      if on_complete then
        on_complete(result, err)
      end
      return
    end
    if result.state then
      self:_render(result.state, selection)
    end
    if result.failure and not session.output:is_open() then
      local message = vim.trim(mutation_error(result.failure):gsub("\27%[[0-9;]*m", ""))
      vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
    end
    if on_complete then
      on_complete(result, nil)
    end
  end)
end

function Workflow:run(context, command)
  local session = self.session
  local root = context.root or session.cwd
  return self:_start_operation(function(operation)
    session.output:start_sequence()
    return self:_run_command(operation, root, command, true)
  end, function(result)
    if not command_succeeded(result) and not session.output:is_open() then
      vim.notify(mutation_error(result), vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

function Workflow:query(root, query, callback)
  return self:_start_operation(function(operation)
    return operation:await(query)
  end, callback)
end

function Workflow:set_revset(root, revset)
  local session = self.session
  local selection, saved_view = session.view:capture_selection()
  self:_start_operation(function(operation)
    return self:_load_repository(operation, root, true, true, revset)
  end, function(state, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    session.revset = revset
    self:_render(state, selection, saved_view)
  end)
end

function Workflow:_finish_editor_mutation(root, command, selection, complete)
  if self.session.operation then
    vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
    complete(false)
    return
  end
  self:mutate({ root = root }, command, selection, false, function(result)
    local succeeded = result and result.succeeded == true
    if not succeeded and result and result.failure and self.session.output:is_open() then
      local message = vim.trim(mutation_error(result.failure):gsub("\27%[[0-9;]*m", ""))
      vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
    end
    complete(succeeded)
  end)
end

function Workflow:commit(context, edit_description)
  local session = self.session
  if session.editor:is_open() then
    session.editor:focus()
    return
  end
  local root = context.root
  local path = context.file and context.file.path
  self:query(root, function(callback)
    return jj.full_description(root, "@", callback)
  end, function(description, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    if not edit_description then
      self:mutate({ root = root }, jj.commit(path, description), true)
      return
    end
    session.editor:open({
      change_id = "@",
      contents = description,
      name = "majjit://commit",
      startinsert = description == "",
      on_submit = function(value, complete)
        self:_finish_editor_mutation(root, jj.commit(path, value), {}, complete)
      end,
    })
  end)
end

local function combined_description(destination, source)
  return "JJ: Description from the destination commit:\n"
    .. destination
    .. "\nJJ: Description from source commit:\n"
    .. source
end

function Workflow:squash_edit(context, destination)
  local session = self.session
  if session.editor:is_open() then
    session.editor:focus()
    return
  end
  local root = context.root
  local source = context.source or context
  local source_id = source.commit.change_id
  local path = source.file and source.file.path

  self:_start_operation(function(operation)
    local destination_id = destination and destination.change_id
    local destination_description
    if destination_id then
      local err
      destination_description, err = operation:await(function(callback)
        return jj.full_description(root, destination_id, callback)
      end)
      if err then
        return nil, err
      end
    else
      local parents, err = operation:await(function(callback)
        return jj.parent_descriptions(root, source_id, callback)
      end)
      if err then
        return nil, err
      end
      if #parents ~= 1 then
        return nil, "Squashing into a parent requires exactly one parent"
      end
      destination_id = parents[1].change_id
      destination_description = parents[1].description
    end
    local source_description, err = operation:await(function(callback)
      return jj.full_description(root, source_id, callback)
    end)
    if err then
      return nil, err
    end
    return {
      destination = destination_id,
      contents = combined_description(destination_description, source_description),
    }
  end, function(result, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    session.editor:open({
      change_id = source_id,
      contents = result.contents,
      name = "majjit://squash/" .. source_id .. "/" .. result.destination,
      startinsert = false,
      on_submit = function(value, complete)
        local command
        if destination then
          command = jj.squash_into(source_id, result.destination, path, false, value)
        else
          command = jj.squash(source_id, path, false, value)
        end
        self:_finish_editor_mutation(root, command, { change_id = result.destination }, complete)
      end,
    })
  end)
end

function Workflow:describe_inline(context)
  local root = context.root
  local change_id = context.commit.change_id
  local description = context.commit.description or ""
  self:input("Describe: ", function(value)
    self:mutate({ root = root }, jj.describe(change_id, value), { change_id = change_id })
  end, description)
end

function Workflow:describe_in_editor(context)
  local session = self.session
  if session.editor:is_open() then
    session.editor:focus()
    return
  end

  local root = context.root
  local change_id = context.commit.change_id
  self:_start_operation(function(operation)
    local template, err = operation:await(function(callback)
      return jj.draft_description_template(root, callback)
    end)
    if err then
      return nil, err
    end
    return operation:await(function(callback)
      return jj.draft_description(root, change_id, vim.trim(template), callback)
    end)
  end, function(contents, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    session.editor:open({
      change_id = change_id,
      contents = contents,
      startinsert = context.commit.description == nil,
      on_submit = function(value, complete)
        if session.operation then
          vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
          complete(false)
          return
        end
        self:mutate(
          { root = root },
          jj.describe(change_id, value),
          { change_id = change_id },
          false,
          function(result)
            local succeeded = result and result.succeeded == true
            if not succeeded and result and result.failure and session.output:is_open() then
              local message = vim.trim(mutation_error(result.failure):gsub("\27%[[0-9;]*m", ""))
              vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
            end
            complete(succeeded)
          end
        )
      end,
    })
  end)
end

function Workflow:_select_repository_value(root, prompt, query, callback, opts)
  opts = opts or {}
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
          next_state, err = repository.load(operation, root, self.session.revset)
          if err then
            return { recovered = true }, err
          end
          items, err = operation:await(query)
        end
        if err then
          return { recovered = append_output, state = next_state }, err
        end
        if opts.manual then
          items[#items + 1] = prompt_module.manual_entry(opts.manual)
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
    allow_custom = opts.allow_custom,
    format_item = opts.format_item,
    input_prompt = opts.input_prompt,
    prompt = prompt,
  }, function(value, selection_err)
    callback(value, append_output, selection_err)
  end)
end

function Workflow:select_values(root, prompt, query, callback, opts)
  return self:_select_repository_value(root, prompt, query, callback, opts)
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

function Workflow:input(prompt, callback, default)
  self.session.prompt:input({ default = default, prompt = prompt }, callback)
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
