local jj = require("majjit.jj")

local M = {}

local DEFAULT_REVSET = "present(@) | ancestors(immutable_heads().., 32) | remote_bookmarks() | root()"

local generation = 0

function M.cancel()
  generation = generation + 1
end

function M.load(cwd, callback)
  generation = generation + 1
  local current_generation = generation

  jj.workspace_root(cwd, function(root, root_err)
    if current_generation ~= generation then
      return
    end
    if root_err then
      callback(nil, root_err)
      return
    end

    jj.log(root, DEFAULT_REVSET, function(output, log_err)
      if current_generation ~= generation then
        return
      end
      if log_err then
        callback(nil, log_err)
        return
      end

      callback({
        root = root,
        revset = DEFAULT_REVSET,
        log_lines = vim.split(vim.trim(output), "\n", { plain = true }),
      }, nil)
    end)
  end)
end

return M
