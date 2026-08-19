local M = {}

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

function M.workspace_root(repository, callback)
  return run(repository, { "workspace", "root" }, { color = "never" }, function(output, err)
    callback(output and vim.trim(output), err)
  end)
end

function M.diff_summary(repository, change_id, callback)
  return run(
    repository,
    { "diff", "--ignore-working-copy", "--summary", "--revisions", change_id },
    { color = "never" },
    callback
  )
end

function M.log(repository, revset, template, callback)
  return run(
    repository,
    { "log", "--template", template, "--revisions", revset },
    { color = "always" },
    callback
  )
end

return M
