local jj = require("majjit.jj")

local M = {}

local FIELD_MARKER = "_MAJJIT_"
local FIELD_COUNT = 12
local FOLD_CLOSED = "▸"
local FOLD_OPEN = "▾"
local GRAPH_CHARACTERS = {
  [" "] = true,
  ["│"] = true,
  ["├"] = true,
  ["┤"] = true,
  ["┬"] = true,
  ["┴"] = true,
  ["╭"] = true,
  ["╮"] = true,
  ["╯"] = true,
  ["╰"] = true,
  ["─"] = true,
  ["┼"] = true,
}
local TEMPLATE = [=[
stringify(concat(
  "_MAJJIT_", change_id.shortest(8), if(divergent, "/" ++ change_offset),
  "_MAJJIT_", commit_id.shortest(8),
  "_MAJJIT_", if(current_working_copy, "Y", "N"),
  "_MAJJIT_", if(conflict, "Y", "N"),
  "_MAJJIT_", if(empty, "Y", "N"),
  "_MAJJIT_", if(root, "Y", "N"),
  "_MAJJIT_", working_copies,
  "_MAJJIT_", local_bookmarks.map(|b| b.name()).join(" "),
  "_MAJJIT_", tags.map(|t| t.name()).join(" "),
  "_MAJJIT_", coalesce(author.email(), ""),
  "_MAJJIT_", author.timestamp().local().format("%Y-%m-%d %H:%M:%S"),
  "_MAJJIT_", coalesce(description.first_line(), ""),
  "_MAJJIT_"
)) ++ builtin_log_compact
]=]

local function split_words(value)
  if value == "" then
    return {}
  end
  return vim.split(value, "%s+")
end

local function strip_ansi(value)
  return (value:gsub("\27%[[0-9;]*m", ""))
end

local function characters(value)
  return vim.fn.split(value, "\\zs")
end

local function split_line2(line)
  if not line then
    return "", ""
  end

  local chars = characters(line)
  local gutter = {}
  local i = 1
  while chars[i] and GRAPH_CHARACTERS[chars[i]] do
    gutter[#gutter + 1] = chars[i]
    i = i + 1
  end

  local body = {}
  while chars[i] do
    body[#body + 1] = chars[i]
    i = i + 1
  end
  return table.concat(gutter), table.concat(body)
end

-- Keep graph branches that must continue through rows inserted below a commit.
local function derive_graph_indent(line1_gutter, line2_gutter)
  local line1 = characters(strip_ansi(line1_gutter))
  local line2 = characters(line2_gutter)
  table.remove(line2)

  local indent = {}
  for i, line2_char in ipairs(line2) do
    local line1_char = line1[i] or " "
    if
      line2_char == "│"
      or line2_char == "├"
      or line2_char == "┤"
      or line2_char == "┬"
      or line2_char == "╭"
      or line2_char == "╮"
      or line2_char == "┼"
      or (line2_char == "─" and line1_char == "│")
    then
      indent[#indent + 1] = "│"
    else
      indent[#indent + 1] = " "
    end
  end
  return table.concat(indent)
end

local function parse_commit(line1, line2)
  local first_marker = line1:find(FIELD_MARKER, 1, true)
  local last_marker = first_marker
  local search_from = first_marker + #FIELD_MARKER

  while true do
    local marker = line1:find(FIELD_MARKER, search_from, true)
    if not marker then
      break
    end
    last_marker = marker
    search_from = marker + #FIELD_MARKER
  end

  if first_marker == last_marker then
    return nil, "Commit line has only one " .. FIELD_MARKER .. " marker"
  end

  local marker_block = line1:sub(first_marker, last_marker + #FIELD_MARKER - 1)
  local parts = vim.split(strip_ansi(marker_block), FIELD_MARKER, {
    plain = true,
    trimempty = false,
  })
  if #parts ~= FIELD_COUNT + 2 then
    return nil, ("Commit marker block has %d fields, expected %d"):format(#parts - 2, FIELD_COUNT)
  end

  local fields = {}
  for i = 1, FIELD_COUNT do
    fields[i] = parts[i + 1]
  end

  local line1_gutter = line1:sub(1, first_marker - 1)
  if line1_gutter:sub(-2) == "  " then
    line1_gutter = line1_gutter:sub(1, -3)
  end
  local line2_gutter, line2_body = split_line2(line2)

  return {
    kind = "commit",
    change_id = fields[1],
    commit_id = fields[2],
    current_working_copy = fields[3] == "Y",
    has_conflict = fields[4] == "Y",
    empty = fields[5] == "Y",
    root = fields[6] == "Y",
    workspaces = split_words(fields[7]),
    bookmarks = split_words(fields[8]),
    tags = split_words(fields[9]),
    email = fields[10],
    timestamp = fields[11],
    description = fields[12] ~= "" and fields[12] or nil,
    expanded = false,
    files = {},
    graph_indent = derive_graph_indent(line1_gutter, line2_gutter),
    line1_body = line1:sub(last_marker + #FIELD_MARKER),
    line1_gutter = line1_gutter,
    line2_body = line2_body,
    line2_gutter = line2_gutter,
    loaded = false,
  }, nil
end

local function render_commit(commit)
  local fold = commit.expanded and FOLD_OPEN or FOLD_CLOSED
  local lines = {
    commit.line1_gutter .. " " .. fold .. " " .. commit.line1_body,
  }
  if commit.line2_body ~= "" then
    lines[#lines + 1] = commit.line2_gutter .. " " .. commit.line2_body
  end
  commit.fold_column = #strip_ansi(commit.line1_gutter) + 1
  return lines
end

local function render_file(file)
  file.fold_column = #file.graph_indent
  file.content_column = file.fold_column + #FOLD_CLOSED + 1
  return {
    file.graph_indent .. FOLD_CLOSED .. " " .. file.status_label .. " " .. file.description,
  }
end

function M.flatten(revision_log)
  local entries = {}
  local lines = {}
  local current_line

  local function append(entry, entry_lines)
    entry.line = #lines + 1
    entry.lines = entry_lines
    entries[#entries + 1] = entry
    vim.list_extend(lines, entry_lines)
  end

  for _, item in ipairs(revision_log.items) do
    if item.kind == "commit" then
      append(item, render_commit(item))
      if item.current_working_copy then
        current_line = item.line
      end
      if item.expanded then
        for _, file in ipairs(item.files) do
          append(file, render_file(file))
        end
      end
    else
      append(item, item.lines)
    end
  end

  revision_log.entries = entries
  revision_log.lines = lines
  revision_log.current_line = current_line
end

function M.parse(output, revset)
  output = vim.trim(output)
  if output == "" then
    return nil, ("Revset '%s' is empty"):format(revset)
  end

  local output_lines = vim.split(output, "\n", { plain = true })
  local items = {}
  local i = 1

  while i <= #output_lines do
    local line1 = output_lines[i]
    if not line1:find(FIELD_MARKER, 1, true) then
      items[#items + 1] = {
        kind = "text",
        lines = { line1 },
      }
      i = i + 1
    else
      local line2
      if output_lines[i + 1] and not output_lines[i + 1]:find(FIELD_MARKER, 1, true) then
        line2 = output_lines[i + 1]
        i = i + 1
      end

      local commit, err = parse_commit(line1, line2)
      if err then
        return nil, err
      end

      items[#items + 1] = commit
      i = i + 1
    end
  end

  local revision_log = { items = items }
  M.flatten(revision_log)
  return revision_log, nil
end

function M.entry_at_line(revision_log, line)
  for index, entry in ipairs(revision_log.entries) do
    local offset = line - entry.line
    if offset >= 0 and offset < #entry.lines then
      return entry, offset, index
    end
  end
end

function M.find_commit(revision_log, change_id)
  for _, entry in ipairs(revision_log.items) do
    if entry.kind == "commit" and entry.change_id == change_id then
      return entry
    end
  end
end

function M.find_file(revision_log, change_id, path)
  for _, entry in ipairs(revision_log.entries) do
    if entry.kind == "file" and entry.change_id == change_id and entry.path == path then
      return entry
    end
  end
end

function M.current_commit(revision_log)
  for _, entry in ipairs(revision_log.items) do
    if entry.kind == "commit" and entry.current_working_copy then
      return entry
    end
  end
end

function M.load(repository, revset, callback)
  return jj.log(repository, revset, TEMPLATE, function(output, err)
    if err then
      callback(nil, err)
      return
    end
    callback(M.parse(output, revset))
  end)
end

return M
