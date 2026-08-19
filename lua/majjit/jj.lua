local M = {}

local function run(repository, args, callback)
  local command = { "jj", "--color", "never", "--repository", repository }
  vim.list_extend(command, args)

  local ok, err = pcall(vim.system, command, { text = true }, vim.schedule_wrap(callback))
  if not ok then
    vim.schedule(function()
      callback({ code = -1, stderr = tostring(err) })
    end)
  end
end

function M.workspace_root(repository, callback)
  run(repository, { "workspace", "root" }, function(result)
    if result.code == 0 then
      callback(vim.trim(result.stdout), nil)
      return
    end

    local message = vim.trim(result.stderr)
    if message == "" then
      message = ("jj exited with code %d"):format(result.code)
    end
    callback(nil, message)
  end)
end

return M
