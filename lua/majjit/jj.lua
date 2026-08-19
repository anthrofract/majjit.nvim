local M = {}

local REVISION_TARGET_TEMPLATE = [=[
change_id.shortest(8) ++ "\n"
  ++ commit_id.shortest(8) ++ "\n"
  ++ local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"
  ++ remote_bookmarks.filter(|b| b.remote() != "git").map(|b| b.name() ++ "@" ++ b.remote()).join("\n") ++ "\n"
  ++ tags.map(|t| t.name()).join("\n") ++ "\n"
  ++ working_copies ++ "\n"
]=]

local function run(repository, args, opts, callback)
  local command = { "jj", "--color", opts.color, "--no-pager", "--repository", repository }
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

function M.git_fetch()
  return mutation({ "git", "fetch" })
end

function M.log(repository, revset, template, callback)
  return run(
    repository,
    { "log", "--template", template, "--revisions", revset },
    { color = "always" },
    callback
  )
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

      local targets = {}
      local seen = {}
      for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
        local target = vim.trim(line)
        if target ~= "" and not seen[target] then
          seen[target] = true
          targets[#targets + 1] = target
        end
      end
      table.sort(targets)
      callback(targets, nil)
    end
  )
end

function M.run_mutation(repository, command, callback)
  local args = { "jj", "--color", "always", "--no-pager", "--repository", repository }
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

function M.undo()
  return mutation({ "undo" })
end

return M
