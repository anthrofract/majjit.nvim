local jj = require("majjit.jj")

local M = {}

local STATUS_LABELS = {
  A = "new file",
  C = "copied  ",
  D = "deleted ",
  M = "modified",
  R = "renamed ",
}

local function parse_file(change_id, graph_indent, line)
  local status, description = line:match("^([MADRC])%s+(.+)$")
  if not status or not STATUS_LABELS[status] then
    return nil, "Cannot parse file diff: " .. line
  end

  local path = description
  if status == "R" or status == "C" then
    local prefix, _, destination, suffix = description:match("^(.-){(.-)%s*=>%s*(.-)}(.*)$")
    if not prefix then
      return nil, "Cannot parse renamed or copied file diff: " .. line
    end
    path = prefix .. destination .. suffix
  end

  return {
    kind = "file",
    change_id = change_id,
    description = description,
    graph_indent = graph_indent,
    loaded = false,
    expanded = false,
    path = path,
    status = status,
    status_label = STATUS_LABELS[status],
  }, nil
end

function M.parse_summary(output, change_id, graph_indent)
  output = vim.trim(output)
  if output == "" then
    return {}, nil
  end

  local files = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local file, err = parse_file(change_id, graph_indent, line)
    if err then
      return nil, err
    end
    files[#files + 1] = file
  end
  return files, nil
end

function M.load_summary(repository, change_id, graph_indent, callback)
  return jj.diff_summary(repository, change_id, function(output, err)
    if err then
      callback(nil, err)
      return
    end
    callback(M.parse_summary(output, change_id, graph_indent))
  end)
end

return M
