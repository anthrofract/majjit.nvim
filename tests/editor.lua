local editor_module = require("majjit.commands.editor")

vim.cmd.vsplit()
local window = vim.api.nvim_get_current_win()
local window_count = #vim.api.nvim_tabpage_list_wins(0)
local source_buffer = vim.api.nvim_create_buf(true, false)
vim.bo[source_buffer].bufhidden = "wipe"
vim.api.nvim_win_set_buf(window, source_buffer)
local editor = editor_module.new(function()
  return window
end)
local submitted
local complete

assert(editor:open({
  change_id = "change-id",
  contents = "old description\n",
  startinsert = false,
  on_submit = function(value, callback)
    submitted = value
    complete = callback
  end,
}))
local editor_buffer = vim.api.nvim_get_current_buf()
assert(editor_buffer ~= source_buffer)
assert(vim.bo[editor_buffer].filetype == "jjdescription")
assert(vim.api.nvim_buf_is_valid(source_buffer))
assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)
assert(vim.fn.maparg("ZZ", "n", false, true).rhs == "<Cmd>write<CR>")

vim.api.nvim_buf_set_lines(editor_buffer, 0, -1, false, { "new description", "JJ: ignored" })
vim.cmd.write()
assert(submitted == "new description")
assert(vim.api.nvim_win_get_buf(window) == editor_buffer)
assert(vim.api.nvim_buf_is_valid(editor_buffer))

complete(false)
assert(vim.api.nvim_win_get_buf(window) == editor_buffer)
assert(vim.bo[editor_buffer].modifiable)

vim.api.nvim_buf_set_lines(editor_buffer, 0, -1, false, { "final description" })
vim.cmd.write()
assert(submitted == "final description")
complete(true)
assert(vim.api.nvim_win_get_buf(window) == source_buffer)
assert(not vim.api.nvim_buf_is_valid(editor_buffer))
assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)

assert(editor:open({
  change_id = "other-change-id",
  contents = "description",
  startinsert = false,
  on_submit = function() end,
}))
editor_buffer = vim.api.nvim_get_current_buf()
vim.fn.maparg("ZQ", "n", false, true).callback()
assert(vim.api.nvim_win_get_buf(window) == source_buffer)
assert(not vim.api.nvim_buf_is_valid(editor_buffer))
assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)

vim.api.nvim_buf_delete(source_buffer, { force = true })
