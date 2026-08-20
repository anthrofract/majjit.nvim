local jump = require("majjit.jump")

local path = vim.fn.tempname()
vim.fn.writefile({ "working file" }, path)

local window = vim.api.nvim_get_current_win()
local majjit_buffer = vim.api.nvim_create_buf(false, true)
vim.bo[majjit_buffer].bufhidden = "wipe"
vim.api.nvim_win_set_buf(window, majjit_buffer)
vim.cmd.vsplit()
local user_window = vim.api.nvim_get_current_win()
local user_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(user_window, user_buffer)
vim.api.nvim_set_current_win(window)

local opened, err = jump.open_working_file(vim.fs.dirname(path), vim.fs.basename(path), majjit_buffer)
assert(opened and not err)
assert(vim.api.nvim_get_current_win() == user_window)
assert(vim.api.nvim_win_get_buf(window) == majjit_buffer)
assert(vim.api.nvim_buf_is_valid(majjit_buffer))
assert(vim.api.nvim_buf_get_name(0) == path)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "working file" }))

vim.api.nvim_win_close(user_window, true)
opened, err = jump.open_working_file(vim.fs.dirname(path), vim.fs.basename(path), majjit_buffer)
assert(opened and not err)
assert(vim.api.nvim_win_get_buf(window) ~= majjit_buffer)
assert(not vim.api.nvim_buf_is_valid(majjit_buffer))

vim.api.nvim_buf_delete(0, { force = true })

local preview_window = vim.api.nvim_get_current_win()
local preview_majjit_buffer = vim.api.nvim_create_buf(false, true)
vim.bo[preview_majjit_buffer].bufhidden = "wipe"
vim.api.nvim_win_set_buf(preview_window, preview_majjit_buffer)
vim.cmd.vsplit()
local preview_user_window = vim.api.nvim_get_current_win()
local return_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(preview_user_window, return_buffer)
vim.api.nvim_set_current_win(preview_window)

opened, err = jump.open_historical_file(
  "commit-id",
  "example.lua",
  "historical\ncontents\n",
  preview_majjit_buffer
)
assert(opened and not err)
local historical_buffer = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_get_current_win() == preview_user_window)
assert(vim.api.nvim_win_get_buf(preview_window) == preview_majjit_buffer)
assert(vim.api.nvim_buf_is_valid(preview_majjit_buffer))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(historical_buffer, 0, -1, false), { "historical", "contents" }))
assert(vim.bo[historical_buffer].readonly)
assert(not vim.bo[historical_buffer].modifiable)

vim.api.nvim_set_current_win(preview_window)
assert(jump.focus_historical_file("commit-id", "example.lua", preview_majjit_buffer))
assert(vim.api.nvim_get_current_win() == preview_user_window)
vim.fn.maparg("q", "n", false, true).callback()
assert(vim.api.nvim_win_get_buf(preview_user_window) == return_buffer)
assert(not vim.api.nvim_buf_is_valid(historical_buffer))
assert(vim.api.nvim_buf_is_valid(preview_majjit_buffer))

vim.api.nvim_win_close(preview_user_window, true)
opened, err = jump.open_historical_file(
  "other-commit-id",
  "example.lua",
  "replacement",
  preview_majjit_buffer
)
assert(opened and not err)
historical_buffer = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_get_current_win() == preview_window)
assert(not vim.api.nvim_buf_is_valid(preview_majjit_buffer))
vim.fn.maparg("q", "n", false, true).callback()
assert(not vim.api.nvim_buf_is_valid(historical_buffer))

vim.fn.delete(path)
