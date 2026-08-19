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

local function base_command(repository, color)
  local command = { "jj", "--color", color, "--no-pager", "--repository", repository }
  if ignore_immutable then
    command[#command + 1] = "--ignore-immutable"
  end
  return command
end

local function run(repository, args, opts, callback)
  local command = base_command(repository, opts.color)
  vim.list_extend(command, args)

  local function on_exit(result)
    if result.code == 0 then
      callback(result.stdout, nil)
      return
    end

    local message = vim.trim(result.stderr)
    if message == "" then
      message = ("jj exited with code %d"):format(result.code)
    end
    callback(nil, message)
  end

  local ok, process = pcall(vim.system, command, { text = true }, vim.schedule_wrap(on_exit))
  if not ok then
    vim.schedule(function()
      callback(nil, tostring(process))
    end)
    return nil
  end

  return process
end

local function mutation(args)
  return {
    args = args,
    output = "stderr",
  }
end

local function git_mutation(operation, args)
  local command = { "git", operation }
  vim.list_extend(command, args or {})
  return mutation(command)
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

function M.workspace_root(repository, callback)
  return run(repository, { "workspace", "root" }, { color = "never" }, function(output, err)
    callback(output and vim.trim(output), err)
  end)
end

function M.abandon(change_id, flags)
  local args = { "abandon" }
  vim.list_extend(args, flags)
  args[#args + 1] = change_id
  return mutation(args)
end

function M.bookmark_names(repository, callback)
  return run(
    repository,
    { "bookmark", "list", "--all-remotes", "--template", 'name ++ "\\n"' },
    { color = "never" },
    function(output, err)
      callback(output and parse_lines(output) or nil, err)
    end
  )
end

function M.diff_summary(repository, change_id, callback)
  return run(
    repository,
    { "diff", "--ignore-working-copy", "--summary", "--revisions", change_id },
    { color = "never" },
    callback
  )
end

function M.diff_file(repository, change_id, path, callback)
  return run(
    repository,
    { "diff", "--ignore-working-copy", "--color-words", "--revisions", change_id, path },
    { color = "always" },
    callback
  )
end

function M.edit(change_id)
  return mutation({ "edit", change_id })
end

function M.file_show(repository, change_id, path, callback)
  return run(
    repository,
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

function M.git_remote_names(repository, callback)
  return run(repository, { "git", "remote", "list" }, { color = "never" }, function(output, err)
    callback(output and parse_lines(output, function(line)
      return line:match("^%s*(%S+)")
    end) or nil, err)
  end)
end

function M.log(repository, revset, template, callback)
  return run(
    repository,
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
  return mutation(args)
end

function M.redo()
  return mutation({ "redo" })
end

function M.revision_targets(repository, revset, callback)
  return run(
    repository,
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

function M.run_mutation(repository, command, callback)
  local args = base_command(repository, "always")
  vim.list_extend(args, command.args)

  local function on_exit(result)
    callback({
      code = result.code,
      output = result[command.output],
      signal = result.signal,
      stderr = result.stderr,
      stdout = result.stdout,
    })
  end

  local ok, process = pcall(vim.system, args, { text = true }, vim.schedule_wrap(on_exit))
  if not ok then
    vim.schedule(function()
      callback({ error = tostring(process) })
    end)
    return nil
  end

  return process
end

function M.set_ignore_immutable(enabled)
  ignore_immutable = enabled
end

function M.undo()
  return mutation({ "undo" })
end

function M.workspace_update_stale()
  return mutation({ "workspace", "update-stale" })
end

return M
