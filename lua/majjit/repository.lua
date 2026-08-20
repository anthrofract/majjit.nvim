local diff = require("majjit.diff")
local jj = require("majjit.jj")
local log = require("majjit.log")

local M = {}

local DEFAULT_REVSET = "present(@) | ancestors(immutable_heads().., 32) | remote_bookmarks() | root()"
M.DEFAULT_REVSET = DEFAULT_REVSET

function M.load(operation, cwd, revset)
  revset = revset or DEFAULT_REVSET
  local root, root_err = operation:await(function(callback)
    return jj.workspace_root(cwd, callback)
  end)
  if root_err then
    return nil, root_err
  end

  local revision_log, log_err = operation:await(function(callback)
    return log.load(root, revset, callback)
  end)
  if log_err then
    return nil, log_err
  end

  local current_commit = log.current_commit(revision_log)
  if current_commit then
    local files, diff_err = operation:await(function(callback)
      return diff.load_summary(root, current_commit.change_id, current_commit.graph_indent, callback)
    end)
    if diff_err then
      return nil, diff_err
    end
    current_commit.expanded = true
    current_commit.files = files
    current_commit.loaded = true
    log.flatten(revision_log)
  end

  return {
    root = root,
    revset = revset,
    log = revision_log,
  }, nil
end

function M.load_files(operation, root, commit)
  return operation:await(function(callback)
    return diff.load_summary(root, commit.change_id, commit.graph_indent, callback)
  end)
end

function M.load_hunks(operation, root, file)
  return operation:await(function(callback)
    return diff.load_file(root, file, callback)
  end)
end

function M.load_file(operation, root, change_id, path)
  return operation:await(function(callback)
    return jj.file_show(root, change_id, path, callback)
  end)
end

return M
