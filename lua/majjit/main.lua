local M = {}

local ansi = require("baleia").setup({
  async = false,
  name = "MajjitAnsi",
})
local HEADER_LINE_COUNT = 2
local FOLD_MARKER_WIDTH = #"▸"
local buffer
local command_catalog = require("majjit.commands.catalog")
local command_output
local command_prompt
local command_session
local command_tree = require("majjit.commands.tree").compile(command_catalog)
local commands = require("majjit.commands.session")
local directory
local jump = require("majjit.jump")
local jj = require("majjit.jj")
local log = require("majjit.log")
local ignore_immutable = false
local active_mutation
local namespace = vim.api.nvim_create_namespace("majjit")
local output_module = require("majjit.commands.output")
local prompt_module = require("majjit.commands.prompt")
local repository = require("majjit.repository")
local state
local user_window

vim.api.nvim_set_hl(0, "MajjitDiffChange", {
  bold = true,
  default = true,
})

local function get_window()
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == buffer then
    return current
  end
  return vim.fn.win_findbuf(buffer)[1]
end

local function get_context()
  local context = {
    buffer = buffer,
    capabilities = {
      repository = state ~= nil,
    },
    root = state and state.root,
    state = state,
    window = get_window(),
  }
  if not state or not context.window then
    return context
  end

  local cursor = vim.api.nvim_win_get_cursor(context.window)
  context.entry = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
  context.commit = log.commit_for_entry(state.log, context.entry)
  context.file = log.file_for_entry(state.log, context.entry)
  context.capabilities.commit = context.commit ~= nil
  context.capabilities.file = context.file ~= nil
  context.capabilities.foldable = context.entry ~= nil
    and (context.entry.kind == "commit" or context.entry.kind == "file" or context.entry.kind == "hunk")
  context.capabilities.working_copy = context.commit ~= nil and context.commit.current_working_copy
  return context
end

local function set_lines(target, lines)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(target, namespace, 0, -1)
  ansi.once(target)
  vim.bo[target].modifiable = false
end

local function highlight_header(target, root, revset)
  local repository_label = "repository: "
  local revset_label = "  revset: "
  local root_start = #repository_label
  local revset_label_start = root_start + #root
  local revset_start = revset_label_start + #revset_label

  vim.api.nvim_buf_set_extmark(target, namespace, 0, 0, {
    end_col = root_start,
    hl_group = "Label",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, root_start, {
    end_col = revset_label_start,
    hl_group = "String",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, revset_label_start, {
    end_col = revset_start,
    hl_group = "Label",
  })
  vim.api.nvim_buf_set_extmark(target, namespace, 0, revset_start, {
    end_col = revset_start + #revset,
    hl_group = "String",
  })
  if ignore_immutable then
    local option_start = revset_start + #revset + 2
    vim.api.nvim_buf_set_extmark(target, namespace, 0, option_start, {
      end_col = option_start + #"--ignore-immutable",
      hl_group = "DiagnosticError",
    })
  end
end

local function highlight_log(target, revision_log)
  for _, entry in ipairs(revision_log.entries) do
    if entry.kind == "commit" or entry.kind == "file" or entry.kind == "hunk" then
      local row = entry.line + HEADER_LINE_COUNT - 1
      vim.api.nvim_buf_set_extmark(target, namespace, row, entry.fold_column, {
        end_col = entry.fold_column + FOLD_MARKER_WIDTH,
        hl_group = "Comment",
      })

      if entry.kind == "file" then
        vim.api.nvim_buf_set_extmark(target, namespace, row, entry.content_column, {
          end_col = #entry.lines[1],
          hl_group = "Directory",
        })
      end
    elseif entry.kind == "diff_line" and entry.changed then
      local row = entry.line + HEADER_LINE_COUNT - 1
      vim.api.nvim_buf_set_extmark(target, namespace, row, entry.content_column, {
        end_col = #entry.lines[1],
        hl_group = "MajjitDiffChange",
        hl_mode = "combine",
      })
    end
  end
end

local function capture_selection(target)
  if not state then
    return nil, nil
  end

  local windows = vim.fn.win_findbuf(target)
  if not windows[1] then
    return nil, nil
  end

  local window = windows[1]
  local cursor = vim.api.nvim_win_get_cursor(window)
  local selection = {
    column = cursor[2],
    row = cursor[1],
  }
  local entry, offset = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
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

  local view = vim.api.nvim_win_call(window, vim.fn.winsaveview)
  return selection, view
end

local function restore_selection(target, next_state, selection, view)
  local windows = vim.fn.win_findbuf(target)
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
  row = math.max(1, math.min(row or 1, vim.api.nvim_buf_line_count(target)))

  local line = vim.api.nvim_buf_get_lines(target, row - 1, row, false)[1]
  local column = math.min(selection and selection.column or 0, #line)
  local window = windows[1]
  if view then
    view.lnum = row
    view.col = column
    vim.api.nvim_win_call(window, function()
      vim.fn.winrestview(view)
    end)
  end
  vim.api.nvim_win_set_cursor(window, { row, column })
end

local function render(target, next_state, selection, view)
  if not selection and not view then
    selection, view = capture_selection(target)
  end
  local lines = {
    "repository: "
      .. next_state.root
      .. "  revset: "
      .. next_state.revset
      .. (ignore_immutable and "  --ignore-immutable" or ""),
    "",
  }
  vim.list_extend(lines, next_state.log.lines)
  set_lines(target, lines)
  highlight_header(target, next_state.root, next_state.revset)
  highlight_log(target, next_state.log)
  restore_selection(target, next_state, selection, view)
  state = next_state
  if command_session then
    command_session:update_help()
  end
end

local function load(target, selection)
  repository.load(state and state.root or directory, function(next_state, err)
    if target ~= buffer or not vim.api.nvim_buf_is_valid(target) then
      return
    end

    if err then
      if state then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      else
        local lines = vim.split(err, "\n", { plain = true })
        lines[1] = "Error: " .. lines[1]
        set_lines(target, lines)
      end
      return
    end

    render(target, next_state, selection)
  end)
end

local function refresh()
  if not active_mutation and buffer and vim.api.nvim_buf_is_valid(buffer) then
    load(buffer)
  end
end

local function toggle_fold(window)
  if active_mutation or not buffer or not vim.api.nvim_buf_is_valid(buffer) or not state then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(window or 0)
  local entry = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
  if not entry or entry.kind == "diff_line" or entry.kind == "text" then
    return
  end

  if entry.kind == "hunk" then
    local selection, view = capture_selection(buffer)
    entry.expanded = not entry.expanded
    log.flatten(state.log)
    render(buffer, state, selection, view)
    return
  end

  if entry.loaded then
    local selection, view = capture_selection(buffer)
    entry.expanded = not entry.expanded
    log.flatten(state.log)
    render(buffer, state, selection, view)
    return
  end

  local target = buffer
  local current_state = state
  local load_children = entry.kind == "commit" and repository.load_files or repository.load_hunks
  load_children(state.root, entry, function(children, err)
    if target ~= buffer or current_state ~= state or not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end

    local selection, view = capture_selection(target)
    entry.expanded = true
    entry.loaded = true
    if entry.kind == "commit" then
      entry.files = children
    else
      entry.hunks = children
    end
    log.flatten(state.log)
    render(target, state, selection, view)
  end)
end

local function right_click()
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
  toggle_fold(mouse.winid)
end

local function open_file()
  if active_mutation or not buffer or not vim.api.nvim_buf_is_valid(buffer) or not state then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local entry = log.entry_at_line(state.log, cursor[1] - HEADER_LINE_COUNT)
  local file = log.file_for_entry(state.log, entry)
  if not file then
    return
  end

  local commit = log.find_commit(state.log, file.change_id)
  if not commit then
    return
  end

  repository.cancel()
  if commit.current_working_copy then
    local _, err = jump.open_working_file(state.root, file.path, user_window, buffer)
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
    end
    return
  end

  if jump.focus_historical_file(commit.commit_id, file.path) then
    return
  end

  local target = buffer
  local current_state = state
  repository.load_file(state.root, file.change_id, file.path, function(contents, err)
    if target ~= buffer or current_state ~= state or not vim.api.nvim_buf_is_valid(target) then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      return
    end

    local _, open_err = jump.open_historical_file(commit.commit_id, file.path, contents)
    if open_err then
      vim.notify(open_err, vim.log.levels.ERROR, { title = "Majjit" })
    end
  end)
end

local function mutate(context, command_list, select_current)
  if active_mutation then
    vim.notify("A repository operation is already running", vim.log.levels.WARN, { title = "Majjit" })
    return
  end

  if command_list.args then
    command_list = { command_list }
  end
  repository.cancel()
  local target = buffer
  local mutation = {
    commands = command_list,
    index = 0,
    root = context.root or directory,
  }
  active_mutation = mutation
  command_output:start_sequence()
  if command_session then
    command_session:update_mappings()
  end

  local function run_next()
    mutation.index = mutation.index + 1
    local command = mutation.commands[mutation.index]
    command_output:start_command(command)
    mutation.process = jj.run_mutation(mutation.root, command, function(result)
      if active_mutation ~= mutation then
        return
      end

      command_output:finish_command(result)
      if result.error or result.code ~= 0 then
        active_mutation = nil
        if not command_output:is_open() then
          local message = result.error
          if not message or message == "" then
            message = result.stderr
          end
          if not message or message == "" then
            message = "jj exited with code " .. tostring(result.code)
          end
          message = vim.trim(message:gsub("\27%[[0-9;]*m", ""))
          vim.notify(message, vim.log.levels.ERROR, { title = "Majjit" })
        end
        return
      end
      if mutation.index < #mutation.commands then
        run_next()
        return
      end

      active_mutation = nil
      if target == buffer and target and vim.api.nvim_buf_is_valid(target) then
        load(target, select_current and {} or nil)
      end
    end)
  end

  run_next()
end

local function select_revision_target(context, prompt, on_select)
  local root = context.root
  local revset = context.state.revset
  command_prompt:select({
    input_prompt = prompt,
    load = function(callback)
      return jj.revision_targets(root, revset, callback)
    end,
    prompt = prompt,
  }, on_select)
end

local function input_revsets(context)
  local root = context.root
  command_prompt:input({ prompt = "Revsets: " }, function(value)
    mutate({ root = root }, jj.new_revision(value, {}), true)
  end)
end

local function select_bookmark(root, prompt, callback)
  command_prompt:select({
    input_prompt = prompt,
    load = function(on_load)
      return jj.bookmark_names(root, on_load)
    end,
    prompt = prompt,
  }, callback)
end

local function select_git_remote(root, callback)
  command_prompt:select({
    input_prompt = "Fetch remote: ",
    load = function(on_load)
      return jj.git_remote_names(root, on_load)
    end,
    prompt = "Fetch remote: ",
  }, callback)
end

local function reset()
  if active_mutation then
    local mutation = active_mutation
    active_mutation = nil
    if mutation.process then
      pcall(mutation.process.kill, mutation.process, 15)
    end
  end
  if command_session then
    local session = command_session
    command_session = nil
    session:detach()
  end
  if command_prompt then
    command_prompt:cancel()
    command_prompt = nil
  end
  if command_output then
    command_output:close()
    command_output = nil
  end
  repository.cancel()
  ignore_immutable = false
  jj.set_ignore_immutable(false)
  buffer = nil
  directory = nil
  state = nil
  user_window = nil
end

local function close()
  reset()

  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd.tabclose()
  else
    vim.api.nvim_buf_delete(0, { force = true })
  end
end

function M.open()
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    local windows = vim.fn.win_findbuf(buffer)
    if windows[1] then
      vim.api.nvim_set_current_win(windows[1])
      return
    end
  end

  directory = vim.fn.getcwd()
  state = nil
  user_window = vim.api.nvim_get_current_win()

  vim.cmd.tabnew()
  buffer = vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_set_name(buffer, "Majjit")
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].filetype = "majjit"
  vim.bo[buffer].swapfile = false
  vim.wo.cursorline = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  command_output = output_module.new(get_window, ansi)
  command_prompt = prompt_module.new({
    can_start = function()
      return active_mutation == nil
    end,
    get_buffer = function()
      return buffer
    end,
    output = command_output,
    update_mappings = function()
      if command_session then
        command_session:update_mappings()
      end
    end,
  })

  local target = buffer
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = target,
    once = true,
    callback = function()
      if buffer == target then
        reset()
      end
    end,
  })

  set_lines(buffer, { "Loading..." })

  command_session = commands.attach({
    actions = {
      ["git.fetch.default"] = function(context)
        mutate(context, jj.git_fetch(), true)
      end,
      ["git.fetch.all_remotes"] = function(context)
        mutate(context, jj.git_fetch({ "--all-remotes" }), true)
      end,
      ["git.fetch.tracked"] = function(context)
        mutate(context, jj.git_fetch({ "--tracked" }), true)
      end,
      ["git.fetch.branch"] = function(context)
        local root = context.root
        select_bookmark(root, "Fetch branch: ", function(name)
          mutate({ root = root }, jj.git_fetch({ "-b", name }), true)
        end)
      end,
      ["git.fetch.remote"] = function(context)
        local root = context.root
        select_git_remote(root, function(remote)
          mutate({ root = root }, jj.git_fetch({ "--remote", remote }), true)
        end)
      end,
      ["git.push.default"] = function(context)
        mutate(context, jj.git_push(), true)
      end,
      ["git.push.all"] = function(context)
        mutate(context, jj.git_push({ "--all" }), true)
      end,
      ["git.push.revision"] = function(context)
        mutate(context, jj.git_push({ "-r", context.commit.change_id }), true)
      end,
      ["git.push.tracked"] = function(context)
        mutate(context, jj.git_push({ "--tracked" }), true)
      end,
      ["git.push.deleted"] = function(context)
        mutate(context, jj.git_push({ "--deleted" }), true)
      end,
      ["git.push.change"] = function(context)
        mutate(context, jj.git_push({ "-c", context.commit.change_id }), true)
      end,
      ["git.push.named"] = function(context)
        local root = context.root
        local change_id = context.commit.change_id
        command_prompt:input({ prompt = "Bookmark name: " }, function(name)
          mutate({ root = root }, jj.git_push({ "--named", name .. "=" .. change_id }), true)
        end)
      end,
      ["git.push.bookmark"] = function(context)
        local root = context.root
        select_bookmark(root, "Push bookmark: ", function(name)
          mutate({ root = root }, jj.git_push({ "-b", name }), true)
        end)
      end,
      ["operation.redo"] = function(context)
        mutate(context, jj.redo())
      end,
      ["operation.undo"] = function(context)
        mutate(context, jj.undo())
      end,
      ["options.ignore_immutable"] = function()
        ignore_immutable = not ignore_immutable
        jj.set_ignore_immutable(ignore_immutable)
        if buffer and state and vim.api.nvim_buf_is_valid(buffer) then
          render(buffer, state)
        end
      end,
      ["revision.abandon.selection"] = function(context)
        mutate(context, jj.abandon(context.commit.change_id, {}))
      end,
      ["revision.abandon.retain_bookmarks"] = function(context)
        mutate(context, jj.abandon(context.commit.change_id, { "--retain-bookmarks" }))
      end,
      ["revision.abandon.restore_descendants"] = function(context)
        mutate(context, jj.abandon(context.commit.change_id, { "--restore-descendants" }))
      end,
      ["revision.edit.selection"] = function(context)
        mutate(context, jj.edit(context.commit.change_id))
      end,
      ["revision.edit.target"] = function(context)
        local root = context.root
        select_revision_target(context, "Edit: ", function(selected)
          mutate({ root = root }, jj.edit(selected), true)
        end)
      end,
      ["revision.new.after"] = function(context)
        mutate(context, jj.new_revision(context.commit.change_id, {}), true)
      end,
      ["revision.new.insert_after"] = function(context)
        mutate(context, jj.new_revision(context.commit.change_id, { "--insert-after" }), true)
      end,
      ["revision.new.insert_before"] = function(context)
        mutate(context, jj.new_revision(context.commit.change_id, { "--no-edit", "--insert-before" }), true)
      end,
      ["revision.new.trunk"] = function(context)
        mutate(context, jj.new_revision("trunk()", {}), true)
      end,
      ["revision.new.trunk_sync"] = function(context)
        mutate(context, { jj.git_fetch(), jj.new_revision("trunk()", {}) }, true)
      end,
      ["revision.new.target"] = function(context)
        local root = context.root
        select_revision_target(context, "New after: ", function(selected)
          mutate({ root = root }, jj.new_revision(selected, {}), true)
        end)
      end,
      ["revision.new.revsets"] = function(context)
        input_revsets(context)
      end,
      ["view.close"] = function()
        close()
      end,
      ["view.open"] = function()
        open_file()
      end,
      ["view.refresh"] = function()
        refresh()
      end,
      ["view.right_click"] = function()
        right_click()
      end,
      ["view.toggle"] = function()
        toggle_fold()
      end,
    },
    buffer = buffer,
    get_context = get_context,
    get_window = get_window,
    overlay = command_output,
    tree = command_tree,
  })

  load(buffer)
end

return M
