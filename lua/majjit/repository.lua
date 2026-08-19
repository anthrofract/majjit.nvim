local jj = require("majjit.jj")
local log = require("majjit.log")

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

    log.load(root, DEFAULT_REVSET, function(revision_log, log_err)
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
        log = revision_log,
      }, nil)
    end)
  end)
end

return M
