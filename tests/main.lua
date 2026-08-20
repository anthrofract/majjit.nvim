local close
local load_count = 0

package.loaded["majjit.commands.actions"] = {
  new = function(_, close_session)
    close = close_session
    return {}
  end,
}
package.loaded["majjit.workflow"] = {
  new = function()
    return {
      load = function()
        load_count = load_count + 1
      end,
    }
  end,
}

local main = require("majjit.main")
local window = vim.api.nvim_get_current_win()
local original_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(window, original_buffer)
vim.api.nvim_buf_set_lines(original_buffer, 0, -1, false, { "unsaved" })
vim.bo[original_buffer].modified = true
vim.wo[window].number = true
vim.wo[window].relativenumber = true

main.open()
local majjit_buffer = vim.api.nvim_win_get_buf(window)
assert(majjit_buffer ~= original_buffer)
assert(vim.fn.buflisted(majjit_buffer) == 1)
assert(vim.bo[majjit_buffer].filetype == "majjit")
assert(not vim.wo[window].number)
assert(not vim.wo[window].relativenumber)
assert(load_count == 1)

main.open()
assert(vim.api.nvim_win_get_buf(window) == majjit_buffer)
assert(load_count == 1)

close()
assert(vim.api.nvim_win_get_buf(window) == original_buffer)
assert(not vim.api.nvim_buf_is_valid(majjit_buffer))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(original_buffer, 0, -1, false), { "unsaved" }))
assert(vim.bo[original_buffer].modified)
assert(vim.wo[window].number)
assert(vim.wo[window].relativenumber)

vim.api.nvim_buf_delete(original_buffer, { force = true })
