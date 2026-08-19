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

function M.workspace_root(repository, callback)
  return run(repository, { "workspace", "root" }, { color = "never" }, function(output, err)
    callback(output and vim.trim(output), err)
  end)
end

function M.abandon(repository, change_id, callback)
  return run(repository, { "abandon", change_id }, { color = "never" }, callback)
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

function M.edit(repository, change_id, callback)
  return run(repository, { "edit", change_id }, { color = "never" }, callback)
end

function M.file_show(repository, change_id, path, callback)
  return run(
    repository,
    { "file", "show", "--revision", change_id, path },
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

function M.new_revision(repository, target, callback)
  return run(repository, { "new", target }, { color = "never" }, callback)
end

function M.redo(repository, callback)
  return run(repository, { "redo" }, { color = "never" }, callback)
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

function M.undo(repository, callback)
  return run(repository, { "undo" }, { color = "never" }, callback)
end

return M
