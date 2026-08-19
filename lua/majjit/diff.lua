local jj = require("majjit.jj")

local M = {}

local NON_NUMBERED_LINES = {
  ["(binary)"] = true,
  ["(empty)"] = true,
  ["~"] = true,
}
local STATUS_LABELS = {
  A = "new file",
  C = "copied  ",
  D = "deleted ",
  M = "modified",
  R = "renamed ",
}

local function strip_ansi(value)
  return (value:gsub("\27%[[0-9;]*m", ""))
end

local function parse_summary_line(change_id, graph_indent, line)
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
    hunks = {},
    path = path,
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
    local file, err = parse_summary_line(change_id, graph_indent, line)
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

local function find_line_numbers(lines, reverse)
  local red
  local green
  local start = reverse and #lines or 1
  local finish = reverse and 1 or #lines
  local step = reverse and -1 or 1

  for i = start, finish, step do
    local line = strip_ansi(lines[i].ansi)
    if not NON_NUMBERED_LINES[vim.trim(line)] then
      local red_match, green_match = line:match("^%s*(%d*)%s+(%d*):")
      if red_match == nil then
        return nil, nil, "Cannot parse diff hunk line: " .. line
      end
      red = red or (red_match ~= "" and tonumber(red_match) or nil)
      green = green or (green_match ~= "" and tonumber(green_match) or nil)
      if red and green then
        break
      end
    end
  end

  return red or 0, green or 0, nil
end

local function remove_first(value, needle)
  if needle == "" then
    return value
  end
  local start = value:find(needle, 1, true)
  if not start then
    return value
  end
  return value:sub(1, start - 1) .. value:sub(start + #needle)
end

local function parse_hunk(lines, change_id, path, graph_indent, index)
  local red_start, green_start, start_err = find_line_numbers(lines, false)
  if start_err then
    return nil, start_err
  end
  local red_end, green_end, end_err = find_line_numbers(lines, true)
  if end_err then
    return nil, end_err
  end

  local max_line_number = math.max(red_end, green_end)
  local digits_minus_one = max_line_number == 0 and 0 or #tostring(max_line_number) - 1
  local padding = string.rep(" ", math.max(0, 3 - digits_minus_one))
  for line_index, line in ipairs(lines) do
    line.ansi = remove_first(line.ansi, padding)
    line.hunk_index = index
    line.index = line_index
  end

  return {
    kind = "hunk",
    change_id = change_id,
    expanded = true,
    graph_indent = graph_indent,
    green_end = green_end,
    green_start = green_start,
    index = index,
    path = path,
    red_end = red_end,
    red_start = red_start,
    children = lines,
  }, nil
end

function M.parse_file(output, change_id, path, graph_indent)
  output = vim.trim(output)
  if output == "" then
    return {}, nil
  end

  local output_lines = vim.split(output, "\n", { plain = true })
  table.remove(output_lines, 1)
  local hunks = {}
  local hunk_lines = {}

  local function push_hunk()
    if #hunk_lines == 0 then
      return nil
    end
    local hunk, err = parse_hunk(hunk_lines, change_id, path, graph_indent, #hunks + 1)
    if err then
      return err
    end
    hunks[#hunks + 1] = hunk
    hunk_lines = {}
  end

  for _, line in ipairs(output_lines) do
    if strip_ansi(line):match("^%s*%.%.%.%s*$") then
      local err = push_hunk()
      if err then
        return nil, err
      end
    else
      hunk_lines[#hunk_lines + 1] = {
        kind = "diff_line",
        ansi = line,
        change_id = change_id,
        graph_indent = graph_indent,
        path = path,
      }
    end
  end

  local err = push_hunk()
  if err then
    return nil, err
  end
  if hunks[#hunks] then
    local last_hunk = hunks[#hunks]
    last_hunk.children[#last_hunk.children + 1] = {
      kind = "diff_line",
      ansi = "\27[35m~\27[0m",
      change_id = change_id,
      graph_indent = graph_indent,
      hunk_index = last_hunk.index,
      index = #last_hunk.children + 1,
      path = path,
    }
  end
  return hunks, nil
end

function M.load_file(repository, file, callback)
  return jj.diff_file(repository, file.change_id, file.path, function(output, err)
    if err then
      callback(nil, err)
      return
    end
    callback(M.parse_file(output, file.change_id, file.path, file.graph_indent))
  end)
end

return M
