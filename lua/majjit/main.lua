local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local active_session
local command_catalog = require("majjit.commands.catalog")
local command_tree = require("majjit.commands.tree").compile(command_catalog)
local commands_module = require("majjit.commands.session")
local jj = require("majjit.jj")
local jump = require("majjit.jump")
local log = require("majjit.log")
local operation_module = require("majjit.operation")
local output_module = require("majjit.commands.output")
local prompt_module = require("majjit.commands.prompt")
local repository = require("majjit.repository")
local view_module = require("majjit.view")

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

local function start_operation(session, fn, callback)
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

local function command_succeeded(result)
  return not result.error and result.code == 0
end

local function run_command(session, operation, root, command, show_output)
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
    return jj.run_mutation(root, command, callback)
  end)
  session.output:finish_command(result)
  return result
end

local function repair_workspace(session, operation, root, show_output)
  return run_command(session, operation, root, jj.workspace_update_stale(), show_output)
end

local function load_repository(session, operation, root, show_recovery, allow_recovery)
  local next_state, err = repository.load(operation, root)
  if not err or allow_recovery == false or not jj.is_stale_error(err) then
    return next_state, err
  end

  local result = repair_workspace(session, operation, root, show_recovery)
  if not command_succeeded(result) then
    return nil, mutation_error(result)
  end
  return repository.load(operation, root)
end

local function show_load_error(session, err)
  if session.view.state then
    vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
  else
    local lines = vim.split(err, "\n", { plain = true })
    lines[1] = "Error: " .. lines[1]
    session.view:set_lines(lines)
  end
end

local function load(session, selection)
  local root = session.view.state and session.view.state.root or session.directory
  local target = session.view.buffer
  return start_operation(session, function(operation)
    return load_repository(session, operation, root, true, true)
  end, function(next_state, err)
    if target ~= session.view.buffer or not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if err then
      show_load_error(session, err)
      return
    end
    session.view:render(next_state, selection)
    if session.commands then
      session.commands:update_help()
    end
  end)
end

local function refresh(session)
  if not session.operation and vim.api.nvim_buf_is_valid(session.view.buffer) then
    load(session)
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

local function toggle_fold(session, window)
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
    session.view:render(state, selection, saved_view)
    if session.commands then
      session.commands:update_help()
    end
    return
  end

  local selection, saved_view = session.view:capture_selection()
  local intent = {
    change_id = entry.change_id,
    kind = entry.kind,
    path = entry.path,
  }
  local initial_state = state
  start_operation(session, function(operation)
    local working_state = initial_state
    local working_entry = entry
    local recovered = false
    local children, err = load_children(operation, working_state, working_entry)
    if err and jj.is_stale_error(err) then
      local recovery = repair_workspace(session, operation, working_state.root, true)
      if not command_succeeded(recovery) then
        return nil, mutation_error(recovery)
      end
      working_state, err = repository.load(operation, working_state.root)
      if err then
        return nil, err
      end
      recovered = true
      working_entry = resolve_entry(working_state, intent)
      if not working_entry then
        return { state = working_state }, "Selection no longer exists after recovering the workspace"
      end
      children, err = load_children(operation, working_state, working_entry)
    end
    if err then
      return { state = recovered and working_state or nil }, err
    end
    return {
      children = children,
      entry = working_entry,
      recovered = recovered,
      state = working_state,
    }
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      if result and result.state then
        session.view:render(result.state, selection, saved_view)
        if session.commands then
          session.commands:update_help()
        end
      end
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    result.entry.expanded = true
    result.entry.loaded = true
    if result.entry.kind == "commit" then
      result.entry.files = result.children
    else
      result.entry.hunks = result.children
    end
    log.flatten(result.state.log)
    if not result.recovered then
      selection, saved_view = session.view:capture_selection()
    end
    session.view:render(result.state, selection, saved_view)
    if session.commands then
      session.commands:update_help()
    end
  end)
end

local function right_click(session)
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
  toggle_fold(session, mouse.winid)
end

local function open_file(session)
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
  start_operation(session, function(operation)
    local working_state = initial_state
    local working_commit = commit
    local recovered = false
    local contents, err = repository.load_file(operation, working_state.root, intent.change_id, intent.path)
    if err and jj.is_stale_error(err) then
      local recovery = repair_workspace(session, operation, working_state.root, true)
      if not command_succeeded(recovery) then
        return nil, mutation_error(recovery)
      end
      working_state, err = repository.load(operation, working_state.root)
      if err then
        return nil, err
      end
      recovered = true
      working_commit = log.find_commit(working_state.log, intent.change_id)
      if not working_commit then
        return { state = working_state }, "Selection no longer exists after recovering the workspace"
      end
      contents, err = repository.load_file(operation, working_state.root, intent.change_id, intent.path)
    end
    if err then
      return { state = recovered and working_state or nil }, err
    end
    return {
      commit = working_commit,
      contents = contents,
      state = working_state,
    }
  end, function(result, err)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    if err then
      if result and result.state then
        session.view:render(result.state, selection, saved_view)
        if session.commands then
          session.commands:update_help()
        end
      end
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end
    if result.state ~= session.view.state then
      session.view:render(result.state, selection, saved_view)
      if session.commands then
        session.commands:update_help()
      end
    end
    local _, open_err = jump.open_historical_file(result.commit.commit_id, intent.path, result.contents)
    if open_err then
      vim.notify(open_err, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

local function mutate(session, context, command_list, select_current, append_output)
  if type(command_list[1]) == "string" then
    command_list = { command_list }
  end
  local root = context.root or session.directory
  local buffer = session.view.buffer
  local selection = select_current and {} or nil
  return start_operation(session, function(operation)
    if append_output and session.output:has_output() then
      session.output:show()
    else
      session.output:start_sequence()
    end
    local changed = false
    for _, command in ipairs(command_list) do
      local result = run_command(session, operation, root, command, true)
      if not command_succeeded(result) and jj.is_stale_error(result) then
        local recovery = repair_workspace(session, operation, root, true)
        if not command_succeeded(recovery) then
          return { failure = recovery }
        end
        changed = true
        result = run_command(session, operation, root, command, true)
      end
      if not command_succeeded(result) then
        local next_state
        if changed then
          next_state = load_repository(session, operation, root, true, false)
        end
        return { failure = result, state = next_state }
      end
      changed = true
    end
    local next_state, err = load_repository(session, operation, root, true, true)
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
      session.view:render(result.state, selection)
      if session.commands then
        session.commands:update_help()
      end
    end
    if result.failure and not session.output:is_open() then
      local message = vim.trim(mutation_error(result.failure):gsub("\27%[[0-9;]*m", ""))
      vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

local function select_repository_value(session, root, prompt, query, callback)
  local append_output = false
  session.prompt:select({
    input_prompt = prompt,
    load = function(on_load)
      return start_operation(session, function(operation)
        local items, err = operation:await(query)
        local next_state
        if err and jj.is_stale_error(err) then
          append_output = true
          local recovery = repair_workspace(session, operation, root, false)
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
            session.view:render(result.state)
            if session.commands then
              session.commands:update_help()
            end
          end
          on_load(nil, err)
          return
        end
        if result.state and vim.api.nvim_buf_is_valid(session.view.buffer) then
          session.view:render(result.state)
          if session.commands then
            session.commands:update_help()
          end
        end
        on_load(result.items, nil)
      end)
    end,
    prompt = prompt,
  }, function(value)
    callback(value, append_output)
  end)
end

local function select_revision_target(session, context, prompt, callback)
  local root = context.root
  local revset = context.revset
  select_repository_value(session, root, prompt, function(on_load)
    return jj.revision_targets(root, revset, on_load)
  end, callback)
end

local function input_revsets(session, context)
  local root = context.root
  session.prompt:input({ prompt = "Revsets: " }, function(value)
    mutate(session, { root = root }, jj.new_revision(value, {}), true)
  end)
end

local function select_bookmark(session, root, prompt, callback)
  select_repository_value(session, root, prompt, function(on_load)
    return jj.bookmark_names(root, on_load)
  end, callback)
end

local function select_git_remote(session, root, callback)
  select_repository_value(session, root, "Fetch remote: ", function(on_load)
    return jj.git_remote_names(root, on_load)
  end, callback)
end

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

  local directory = vim.fn.getcwd()
  local user_window = vim.api.nvim_get_current_win()

  vim.cmd.tabnew()
  local buffer = vim.api.nvim_get_current_buf()
  local session = {
    closed = false,
    commands = nil,
    directory = directory,
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

  session.commands = commands_module.attach({
    actions = {
      ["git.fetch.default"] = function(context)
        mutate(session, context, jj.git_fetch(), true)
      end,
      ["git.fetch.all_remotes"] = function(context)
        mutate(session, context, jj.git_fetch({ "--all-remotes" }), true)
      end,
      ["git.fetch.tracked"] = function(context)
        mutate(session, context, jj.git_fetch({ "--tracked" }), true)
      end,
      ["git.fetch.branch"] = function(context)
        local root = context.root
        select_bookmark(session, root, "Fetch branch: ", function(name, append_output)
          mutate(session, { root = root }, jj.git_fetch({ "-b", name }), true, append_output)
        end)
      end,
      ["git.fetch.remote"] = function(context)
        local root = context.root
        select_git_remote(session, root, function(remote, append_output)
          mutate(session, { root = root }, jj.git_fetch({ "--remote", remote }), true, append_output)
        end)
      end,
      ["git.push.default"] = function(context)
        mutate(session, context, jj.git_push(), true)
      end,
      ["git.push.all"] = function(context)
        mutate(session, context, jj.git_push({ "--all" }), true)
      end,
      ["git.push.revision"] = function(context)
        mutate(session, context, jj.git_push({ "-r", context.commit.change_id }), true)
      end,
      ["git.push.tracked"] = function(context)
        mutate(session, context, jj.git_push({ "--tracked" }), true)
      end,
      ["git.push.deleted"] = function(context)
        mutate(session, context, jj.git_push({ "--deleted" }), true)
      end,
      ["git.push.change"] = function(context)
        mutate(session, context, jj.git_push({ "-c", context.commit.change_id }), true)
      end,
      ["git.push.named"] = function(context)
        local root = context.root
        local change_id = context.commit.change_id
        session.prompt:input({ prompt = "Bookmark name: " }, function(name)
          mutate(session, { root = root }, jj.git_push({ "--named", name .. "=" .. change_id }), true)
        end)
      end,
      ["git.push.bookmark"] = function(context)
        local root = context.root
        select_bookmark(session, root, "Push bookmark: ", function(name, append_output)
          mutate(session, { root = root }, jj.git_push({ "-b", name }), true, append_output)
        end)
      end,
      ["operation.redo"] = function(context)
        mutate(session, context, jj.redo())
      end,
      ["operation.undo"] = function(context)
        mutate(session, context, jj.undo())
      end,
      ["options.ignore_immutable"] = function()
        local enabled = not session.view.ignore_immutable
        jj.set_ignore_immutable(enabled)
        session.view:set_ignore_immutable(enabled)
      end,
      ["revision.abandon.selection"] = function(context)
        mutate(session, context, jj.abandon(context.commit.change_id, {}))
      end,
      ["revision.abandon.retain_bookmarks"] = function(context)
        mutate(session, context, jj.abandon(context.commit.change_id, { "--retain-bookmarks" }))
      end,
      ["revision.abandon.restore_descendants"] = function(context)
        mutate(session, context, jj.abandon(context.commit.change_id, { "--restore-descendants" }))
      end,
      ["revision.edit.selection"] = function(context)
        mutate(session, context, jj.edit(context.commit.change_id))
      end,
      ["revision.edit.target"] = function(context)
        local root = context.root
        select_revision_target(session, context, "Edit: ", function(selected, append_output)
          mutate(session, { root = root }, jj.edit(selected), true, append_output)
        end)
      end,
      ["revision.new.after"] = function(context)
        mutate(session, context, jj.new_revision(context.commit.change_id, {}), true)
      end,
      ["revision.new.insert_after"] = function(context)
        mutate(session, context, jj.new_revision(context.commit.change_id, { "--insert-after" }), true)
      end,
      ["revision.new.insert_before"] = function(context)
        mutate(session, context, jj.new_revision(context.commit.change_id, { "--no-edit", "--insert-before" }), true)
      end,
      ["revision.new.trunk"] = function(context)
        mutate(session, context, jj.new_revision("trunk()", {}), true)
      end,
      ["revision.new.trunk_sync"] = function(context)
        mutate(session, context, { jj.git_fetch(), jj.new_revision("trunk()", {}) }, true)
      end,
      ["revision.new.target"] = function(context)
        local root = context.root
        select_revision_target(session, context, "New after: ", function(selected, append_output)
          mutate(session, { root = root }, jj.new_revision(selected, {}), true, append_output)
        end)
      end,
      ["revision.new.revsets"] = function(context)
        input_revsets(session, context)
      end,
      ["view.close"] = function()
        close(session)
      end,
      ["view.open"] = function()
        open_file(session)
      end,
      ["view.refresh"] = function()
        refresh(session)
      end,
      ["view.right_click"] = function()
        right_click(session)
      end,
      ["view.toggle"] = function()
        toggle_fold(session)
      end,
    },
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

  load(session)
end

return M
