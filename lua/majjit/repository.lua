local jj = require("majjit.jj")
local log = require("majjit.log")

local M = {}

local DEFAULT_REVSET = "present(@) | ancestors(immutable_heads().., 32) | remote_bookmarks() | root()"

local active_process
local generation = 0

function M.cancel()
  generation = generation + 1
  if active_process then
    pcall(active_process.kill, active_process, 15)
    active_process = nil
  end
end

function M.load(cwd, callback)
  M.cancel()
  local current_generation = generation

  active_process = jj.workspace_root(cwd, function(root, root_err)
    if current_generation ~= generation then
      return
    end
    active_process = nil
    if root_err then
      callback(nil, root_err)
      return
    end

    active_process = log.load(root, DEFAULT_REVSET, function(revision_log, log_err)
      if current_generation ~= generation then
        return
      end
      active_process = nil
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
