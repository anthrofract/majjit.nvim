local diff = require("majjit.diff")
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

      local current_commit = log.current_commit(revision_log)
      if not current_commit then
        callback({
          root = root,
          revset = DEFAULT_REVSET,
          log = revision_log,
        }, nil)
        return
      end

      active_process = diff.load_summary(
        root,
        current_commit.change_id,
        current_commit.graph_indent,
        function(files, diff_err)
          if current_generation ~= generation then
            return
          end
          active_process = nil
          if diff_err then
            callback(nil, diff_err)
            return
          end

          current_commit.expanded = true
          current_commit.files = files
          current_commit.loaded = true
          log.flatten(revision_log)
          callback({
            root = root,
            revset = DEFAULT_REVSET,
            log = revision_log,
          }, nil)
        end
      )
    end)
  end)
end

function M.load_files(root, commit, callback)
  M.cancel()
  local current_generation = generation

  active_process = diff.load_summary(root, commit.change_id, commit.graph_indent, function(files, err)
    if current_generation ~= generation then
      return
    end
    active_process = nil
    callback(files, err)
  end)
end

return M
