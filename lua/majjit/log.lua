local jj = require("majjit.jj")

local M = {}

local FIELD_MARKER = "_MAJJIT_"
local FIELD_COUNT = 12
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

  local lines = {
    line1:sub(1, first_marker - 1) .. line1:sub(last_marker + #FIELD_MARKER),
  }
  if line2 then
    lines[#lines + 1] = line2
  end

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
    lines = lines,
  }, nil
end

function M.parse(output, revset)
  output = vim.trim(output)
  if output == "" then
    return nil, ("Revset '%s' is empty"):format(revset)
  end

  local output_lines = vim.split(output, "\n", { plain = true })
  local entries = {}
  local lines = {}
  local current_line
  local i = 1

  while i <= #output_lines do
    local line1 = output_lines[i]
    if not line1:find(FIELD_MARKER, 1, true) then
      entries[#entries + 1] = {
        kind = "text",
        line = #lines + 1,
        lines = { line1 },
      }
      lines[#lines + 1] = line1
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

      commit.line = #lines + 1
      entries[#entries + 1] = commit
      vim.list_extend(lines, commit.lines)
      if commit.current_working_copy then
        current_line = commit.line
      end
      i = i + 1
    end
  end

  return {
    entries = entries,
    lines = lines,
    current_line = current_line,
  }, nil
end

function M.load(repository, revset, callback)
  jj.log(repository, revset, TEMPLATE, function(output, err)
    if err then
      callback(nil, err)
      return
    end
    callback(M.parse(output, revset))
  end)
end

return M
