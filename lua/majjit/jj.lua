local M = {}
local ignore_immutable = false

local REVISION_TARGET_TEMPLATE = [=[
change_id.shortest(8) ++ "\n"
  ++ commit_id.shortest(8) ++ "\n"
  ++ local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"
  ++ remote_bookmarks.filter(|b| b.remote() != "git").map(|b| b.name() ++ "@" ++ b.remote()).join("\n") ++ "\n"
  ++ tags.map(|t| t.name()).join("\n") ++ "\n"
  ++ working_copies ++ "\n"
]=]

local function base_command(repository_path, color)
  local command = { "jj", "--color", color, "--no-pager", "--repository", repository_path }
  if ignore_immutable then
    command[#command + 1] = "--ignore-immutable"
  end
  return command
end

local function execute(repository_path, args, color, callback, stdin)
  local command = base_command(repository_path, color)
  vim.list_extend(command, args)
  local ok, process = pcall(vim.system, command, { stdin = stdin, text = true }, vim.schedule_wrap(callback))
  if not ok then
    vim.schedule(function()
      callback({ error = tostring(process) })
    end)
    return nil
  end
  return process
end

local function run(repository_path, args, opts, callback)
  return execute(repository_path, args, opts.color, function(result)
    if result.error then
      callback(nil, result.error)
      return
    end
    if result.code == 0 then
      callback(result.stdout, nil)
      return
    end

    local message = vim.trim(result.stderr)
    if message == "" then
      message = ("jj exited with code %d"):format(result.code)
    end
    callback(nil, message)
  end)
end

local function git_mutation(operation, args)
  local command = { "git", operation }
  vim.list_extend(command, args or {})
  return command
end

local function append_value(args, flag, value)
  if value ~= nil then
    args[#args + 1] = flag
    args[#args + 1] = value
  end
end

local function string_literal(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    local escapes = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\0"] = "\\0",
      ["\27"] = "\\e",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return escapes[char] or ("\\x%02x"):format(char:byte())
  end) .. '"'
end

local function exact_pattern(value)
  return "exact:" .. string_literal(value)
end

local function change_id_revset(value)
  if value == "@" or value:find("/", 1, true) then
    return value
  end
  return "change_id(" .. string_literal(value) .. ")"
end

local function root_file(path)
  return "root-file:" .. string_literal(path)
end

local function cwd_file(path)
  return "cwd-file:" .. string_literal(path)
end

local function with_file(args, path)
  if path ~= nil then
    args[#args + 1] = root_file(path)
  end
  return args
end

local function mutation(args, display, stdin)
  if display == nil and stdin == nil then
    return args
  end
  return { args = args, display = display, stdin = stdin }
end

local function parse_lines(output, transform)
  local lines = {}
  local seen = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    line = transform and transform(line) or vim.trim(line)
    if line and line ~= "" and not seen[line] then
      seen[line] = true
      lines[#lines + 1] = line
    end
  end
  table.sort(lines)
  return lines
end

local function lines_query(root, args, callback)
  return run(root, args, { color = "never" }, function(output, err)
    callback(output and parse_lines(output) or nil, err)
  end)
end

local function strip_ansi(value)
  value = value:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  value = value:gsub("\27%].-\7", "")
  return (value:gsub("\27%].-\27\\", ""))
end

function M.workspace_root(cwd, callback)
  return run(cwd, { "workspace", "root" }, { color = "never" }, function(output, err)
    callback(output and vim.trim(output), err)
  end)
end

function M.exact_pattern(value)
  return exact_pattern(value)
end

function M.root_file(path)
  return root_file(path)
end

function M.abandon(change_id, flags)
  local args = { "abandon" }
  vim.list_extend(args, flags)
  args[#args + 1] = change_id
  return args
end

function M.absorb(from_change_id, into_change_id, path)
  local args = { "absorb", "--from", from_change_id }
  append_value(args, "--into", into_change_id)
  return with_file(args, path)
end

function M.bookmark_names(root, callback)
  return run(
    root,
    { "bookmark", "list", "--all-remotes", "--template", 'name ++ "\\n"' },
    { color = "never" },
    function(output, err)
      callback(output and parse_lines(output) or nil, err)
    end
  )
end

function M.bookmark_create(name, change_id)
  return { "bookmark", "create", "--revision", change_id, name }
end

function M.bookmark_delete(name)
  return { "bookmark", "delete", exact_pattern(name) }
end

function M.bookmark_forget(name, include_remotes)
  local args = { "bookmark", "forget" }
  if include_remotes then
    args[#args + 1] = "--include-remotes"
  end
  args[#args + 1] = exact_pattern(name)
  return args
end

function M.bookmark_advance(change_id)
  return { "bookmark", "advance", "--to", change_id }
end

function M.bookmark_move(from, to, allow_backwards)
  local args = { "bookmark", "move", "--from", from, "--to", to }
  if allow_backwards then
    args[#args + 1] = "--allow-backwards"
  end
  return args
end

function M.bookmark_rename(old_name, new_name)
  return { "bookmark", "rename", old_name, new_name }
end

function M.bookmark_set(name, change_id, allow_backwards)
  local args = { "bookmark", "set", name, "--revision", change_id }
  if allow_backwards then
    args[#args + 1] = "--allow-backwards"
  end
  return args
end

function M.bookmark_track(name, remote)
  local args = { "bookmark", "track", exact_pattern(name) }
  append_value(args, "--remote", remote and exact_pattern(remote))
  return args
end

function M.bookmark_untrack(name, remote)
  local args = { "bookmark", "untrack", exact_pattern(name) }
  append_value(args, "--remote", remote and exact_pattern(remote))
  return args
end

function M.bookmark_local_names(root, callback)
  return lines_query(root, { "bookmark", "list", "--template", 'if(!remote, name ++ "\\n")' }, callback)
end

function M.bookmark_conflicted_names(root, callback)
  return lines_query(
    root,
    { "bookmark", "list", "--conflicted", "--template", 'if(!remote, name ++ "\\n")' },
    callback
  )
end

function M.bookmark_display_names(root, callback)
  return lines_query(
    root,
    { "bookmark", "list", "--all-remotes", "--template", 'if(remote, name ++ "@" ++ remote, name) ++ "\\n"' },
    callback
  )
end

function M.bookmark_remote_names(root, tracked, callback)
  local args = { "bookmark", "list" }
  if tracked then
    args[#args + 1] = "--tracked"
  else
    args[#args + 1] = "--all-remotes"
  end
  vim.list_extend(args, {
    "--template",
    tracked and 'if(remote, name ++ "\\0" ++ remote ++ "\\0")'
      or 'if(remote && !tracked, name ++ "\\0" ++ remote ++ "\\0")',
  })
  return run(root, args, { color = "never" }, function(output, err)
    if not output then
      callback(nil, err)
      return
    end
    local values = vim.split(output, "\0", { plain = true })
    local bookmarks = {}
    for index = 1, #values - 1, 2 do
      bookmarks[#bookmarks + 1] = { name = values[index], remote = values[index + 1] }
    end
    callback(bookmarks, nil)
  end)
end

function M.diff_summary(root, change_id, callback)
  return run(
    root,
    { "diff", "--ignore-working-copy", "--summary", "--revisions", change_id },
    { color = "never" },
    callback
  )
end

function M.diff_file(root, change_id, path, callback)
  return run(
    root,
    { "diff", "--ignore-working-copy", "--color-words", "--revisions", change_id, root_file(path) },
    { color = "always" },
    callback
  )
end

function M.describe(change_id, description)
  return {
    args = { "describe", change_id, "--stdin" },
    stdin = description,
  }
end

function M.commit(path, message)
  local args = { "commit" }
  append_value(args, "--message", message)
  with_file(args, path)
  local display = vim.deepcopy(args)
  for index, value in ipairs(display) do
    if value == "--message" then
      display[index + 1] = "<description>"
      break
    end
  end
  return mutation(args, display)
end

function M.custom(args, display, stdin)
  assert(type(args) == "table", "custom command arguments must be a list")
  return mutation(vim.deepcopy(args), display, stdin)
end

function M.duplicate(change_id, destination_type, destination)
  local args = { "duplicate", change_id }
  append_value(args, destination_type, destination)
  return args
end

function M.draft_description(root, change_id, template, callback)
  return run(
    root,
    { "log", "--ignore-working-copy", "--no-graph", "--revisions", change_id, "--template", template },
    { color = "never" },
    callback
  )
end

function M.draft_description_template(root, callback)
  return run(
    root,
    { "config", "get", "templates.draft_commit_description" },
    { color = "never" },
    callback
  )
end

function M.edit(change_id)
  return { "edit", change_id }
end

function M.file_show(root, change_id, path, callback)
  return run(
    root,
    { "file", "show", "--revision", change_id, root_file(path) },
    { color = "never" },
    callback
  )
end

function M.file_names(root, callback)
  return lines_query(root, { "file", "list" }, callback)
end

function M.file_track(path)
  return { "file", "track", cwd_file(path) }
end

function M.file_untrack(path)
  return { "file", "untrack", root_file(path) }
end

function M.git_fetch(args)
  return git_mutation("fetch", args)
end

function M.git_push(args)
  return git_mutation("push", args)
end

function M.git_remote_names(root, callback)
  return run(root, { "git", "remote", "list" }, { color = "never" }, function(output, err)
    callback(output and parse_lines(output, function(line)
      return line:match("^%s*(%S+)")
    end) or nil, err)
  end)
end

function M.log(root, revset, template, callback)
  return run(
    root,
    { "log", "--template", template, "--revisions", revset },
    { color = "always" },
    callback
  )
end

function M.config_log_revset(root, callback)
  return run(root, { "config", "get", "revsets.log" }, { color = "never" }, function(output, err)
    callback(output and vim.trim(output), err)
  end)
end

function M.full_description(root, change_id, callback)
  return run(
    root,
    {
      "log",
      "--ignore-working-copy",
      "--no-graph",
      "--revisions",
      change_id_revset(change_id),
      "--template",
      "description",
    },
    { color = "never" },
    callback
  )
end

function M.parent_descriptions(root, change_id, callback)
  return run(
    root,
    {
      "log",
      "--ignore-working-copy",
      "--no-graph",
      "--revisions",
      "parents(" .. change_id_revset(change_id) .. ")",
      "--template",
      'change_id ++ "\\0" ++ description ++ "\\0"',
    },
    { color = "never" },
    function(output, err)
      if not output then
        callback(nil, err)
        return
      end
      local values = vim.split(output, "\0", { plain = true })
      local parents = {}
      for index = 1, #values - 1, 2 do
        parents[#parents + 1] = { change_id = values[index], description = values[index + 1] }
      end
      callback(parents, nil)
    end
  )
end

function M.author_metadata(root, change_id, callback)
  return run(
    root,
    {
      "log",
      "--ignore-working-copy",
      "--no-graph",
      "--revisions",
      change_id,
      "--template",
      'author.name() ++ "\\0" ++ author.email() ++ "\\0" ++ author.timestamp() ++ "\\0"',
    },
    { color = "never" },
    function(output, err)
      if not output then
        callback(nil, err)
        return
      end
      local values = vim.split(output, "\0", { plain = true })
      callback({ name = values[1], email = values[2], timestamp = values[3] }, nil)
    end
  )
end

function M.is_stale_error(value)
  if type(value) == "table" then
    if value.code == 0 or value.error then
      return false
    end
    value = value.stderr
  end
  return type(value) == "string" and strip_ansi(value):find("Run `jj workspace update%-stale` to ") ~= nil
end

function M.author(change_id, flag, value)
  local args = { "metaedit", flag }
  if value ~= nil then
    args[#args + 1] = value
  end
  args[#args + 1] = change_id
  return args
end

function M.set_author(change_id, value)
  return M.author(change_id, "--author", value)
end

function M.set_author_timestamp(change_id, value)
  return M.author(change_id, "--author-timestamp", value)
end

function M.update_author(change_id)
  return M.author(change_id, "--update-author")
end

function M.update_author_timestamp(change_id)
  return M.author(change_id, "--update-author-timestamp")
end

function M.new_revision(target, flags)
  local args = { "new" }
  vim.list_extend(args, flags)
  args[#args + 1] = target
  return args
end

function M.next_prev(direction, mode, offset)
  assert(direction == "next" or direction == "prev", "direction must be next or prev")
  local args = { direction }
  if mode ~= nil then
    args[#args + 1] = mode
  end
  if offset ~= nil then
    args[#args + 1] = tostring(offset)
  end
  return args
end

function M.parallelize(revset)
  return { "parallelize", revset }
end

function M.rebase(source_type, source, placement_type, destination)
  local args = { "rebase" }
  local sources = type(source) == "table" and source or { source }
  local destinations = type(destination) == "table" and destination or { destination }
  for _, value in ipairs(sources) do
    append_value(args, source_type, value)
  end
  for _, value in ipairs(destinations) do
    append_value(args, placement_type, value)
  end
  return args
end

function M.restore(flags, path)
  local args = { "restore" }
  vim.list_extend(args, flags or {})
  return with_file(args, path)
end

function M.revert(revision, destination_type, destination)
  return { "revert", "--revision", revision, destination_type, destination }
end

function M.sign(revset)
  return { "sign", "--revision", revset }
end

function M.unsign(revset)
  return { "unsign", "--revision", revset }
end

function M.simplify_parents(revision, mode)
  return { "simplify-parents", mode, revision }
end

local function squash_args(from_change_id, into_change_id, path, use_destination_message, message)
  local args = { "squash", "--from", from_change_id }
  append_value(args, "--into", into_change_id)
  if use_destination_message then
    args[#args + 1] = "--use-destination-message"
  end
  append_value(args, "--message", message)
  with_file(args, path)
  if message ~= nil then
    local display = vim.deepcopy(args)
    for index, value in ipairs(display) do
      if value == "--message" then
        display[index + 1] = "<description>"
        break
      end
    end
    return mutation(args, display)
  end
  return args
end

function M.squash(change_id, path, use_destination_message, message)
  local command = squash_args(change_id, nil, path, use_destination_message, message)
  local args = command.args or command
  args[2] = "--revision"
  if command.display then
    command.display[2] = "--revision"
  end
  return command
end

function M.squash_into(from_change_id, into_change_id, path, use_destination_message, message)
  return squash_args(from_change_id, into_change_id, path, use_destination_message, message)
end

function M.status()
  return { "status" }
end

function M.redo()
  return { "redo" }
end

function M.revision_targets(root, revset, callback)
  return run(
    root,
    { "log", "--no-graph", "--revisions", revset, "--template", REVISION_TARGET_TEMPLATE },
    { color = "never" },
    function(output, err)
      if err then
        callback(nil, err)
        return
      end

      callback(parse_lines(output), nil)
    end
  )
end

function M.run_mutation(repository_path, command, callback)
  local args = command.args or command
  return execute(repository_path, args, "always", callback, command.stdin)
end

function M.set_ignore_immutable(enabled)
  ignore_immutable = enabled
end

function M.undo()
  return { "undo" }
end

function M.workspace_update_stale()
  return { "workspace", "update-stale" }
end

function M.workspace_names(root, callback)
  return lines_query(
    root,
    { "workspace", "list", "--ignore-working-copy", "--template", 'name ++ "\\n"' },
    callback
  )
end

function M.current_workspace_name(root, callback)
  return run(
    root,
    {
      "workspace",
      "list",
      "--ignore-working-copy",
      "--template",
      'if(target.current_working_copy(), name ++ "\\n")',
    },
    { color = "never" },
    function(output, err)
      callback(output and vim.trim(output), err)
    end
  )
end

function M.workspace_add(destination, name)
  local args = { "workspace", "add" }
  append_value(args, "--name", name)
  args[#args + 1] = destination
  return args
end

function M.workspace_forget(names)
  local args = { "workspace", "forget" }
  if type(names) == "table" then
    vim.list_extend(args, names)
  else
    args[#args + 1] = names
  end
  return args
end

function M.workspace_rename(name)
  return { "workspace", "rename", name }
end

return M
