require("majjit.highlights")

local view_module = require("majjit.view")

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buffer)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
  "revset: all()",
  "",
  "commit info",
  "commit description",
  "file",
  "hunk",
  "diff line",
  "text",
  "one-line commit",
})

local view = view_module.new(buffer, { once = function() end })
view.state = {
  log = {
    entries = {
      { kind = "commit", line = 1, lines = { "commit info", "commit description" } },
      { kind = "file", line = 3, lines = { "file" } },
      { kind = "hunk", line = 4, lines = { "hunk" } },
      { kind = "diff_line", line = 5, lines = { "diff line" } },
      { kind = "text", line = 6, lines = { "text" } },
      { kind = "commit", line = 7, lines = { "one-line commit" } },
    },
  },
}

local function highlighted_rows(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  view:highlight_cursor()
  local rows = {}
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, view.cursor_namespace, 0, -1, { details = true })) do
    assert(extmark[4].line_hl_group == "MajjitCursorLine")
    rows[#rows + 1] = extmark[2]
  end
  return rows
end

local function move_from(row, direction, count)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  assert(view:move_item(direction, count))
  return vim.api.nvim_win_get_cursor(0)[1]
end

assert(vim.deep_equal(highlighted_rows(3), { 2, 3 }))
assert(vim.deep_equal(highlighted_rows(4), { 2, 3 }))
assert(vim.deep_equal(highlighted_rows(5), { 4 }))
assert(vim.deep_equal(highlighted_rows(6), { 5 }))
assert(vim.deep_equal(highlighted_rows(7), { 6 }))
assert(vim.deep_equal(highlighted_rows(8), { 7 }))
assert(vim.deep_equal(highlighted_rows(9), { 8 }))
assert(vim.deep_equal(highlighted_rows(1), {}))
assert(vim.api.nvim_get_hl(0, { link = true, name = "MajjitCursorLine" }).link == "CursorLine")
assert(move_from(3, 1) == 5)
assert(move_from(4, 1) == 5)
assert(move_from(5, -1) == 3)
assert(move_from(5, 1) == 6)
assert(move_from(5, 3) == 8)
assert(move_from(8, 1) == 9)
assert(move_from(9, -5) == 3)
assert(move_from(3, -1) == 3)
assert(move_from(4, -1) == 4)
assert(move_from(9, 1) == 9)
assert(move_from(1, 1) == 2)
assert(move_from(2, 1) == 3)
assert(move_from(2, -1) == 1)

vim.api.nvim_buf_delete(buffer, { force = true })
