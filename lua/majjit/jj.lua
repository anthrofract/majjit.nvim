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

local function execute(repository_path, args, color, callback)
  local command = base_command(repository_path, color)
  vim.list_extend(command, args)
  local ok, process = pcall(vim.system, command, { text = true }, vim.schedule_wrap(callback))
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

function M.abandon(change_id, flags)
  local args = { "abandon" }
  vim.list_extend(args, flags)
  args[#args + 1] = change_id
  return args
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
    { "diff", "--ignore-working-copy", "--color-words", "--revisions", change_id, path },
    { color = "always" },
    callback
  )
end

function M.edit(change_id)
  return { "edit", change_id }
end

function M.file_show(root, change_id, path, callback)
  return run(
    root,
    { "file", "show", "--revision", change_id, path },
    { color = "never" },
    callback
  )
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

function M.is_stale_error(value)
  if type(value) == "table" then
    if value.code == 0 or value.error then
      return false
    end
    value = value.stderr
  end
  return type(value) == "string" and strip_ansi(value):find("Run `jj workspace update%-stale` to ") ~= nil
end

function M.new_revision(target, flags)
  local args = { "new" }
  vim.list_extend(args, flags)
  args[#args + 1] = target
  return args
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
  return execute(repository_path, command, "always", callback)
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

return M
