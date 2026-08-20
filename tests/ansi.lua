local ansi = require("majjit.ansi")

local buffer = vim.api.nvim_create_buf(false, true)
local namespace = vim.api.nvim_get_namespaces().MajjitAnsi

local function render()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "\27[31mred\27[0m plain",
    "\27[32mgreen\27[0m",
    "\27[1;32mbold green\27[0m",
  })
  ansi.once(buffer)
end

local function highlight_groups()
  local groups = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    groups[#groups + 1] = extmark[4].hl_group
  end
  return groups
end

render()
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), {
  "red plain",
  "green",
  "bold green",
}))
assert(vim.deep_equal(highlight_groups(), {
  "MajjitAnsiRed",
  "MajjitAnsiGreen",
  "Bold",
}))
assert(vim.api.nvim_get_hl(0, { link = true, name = "MajjitAnsiGreen" }).link == "DiagnosticOk")
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#123456" })
assert(vim.api.nvim_get_hl(0, { link = false, name = "MajjitAnsiRed" }).fg == 0x123456)
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#654321" })
assert(vim.api.nvim_get_hl(0, { link = false, name = "MajjitAnsiRed" }).fg == 0x654321)

vim.cmd.colorscheme("default")
assert(vim.api.nvim_get_hl(0, { link = true, name = "MajjitAnsiRed" }).link == "DiagnosticError")
assert(vim.deep_equal(highlight_groups(), {
  "MajjitAnsiRed",
  "MajjitAnsiGreen",
  "Bold",
}))

render()
assert(vim.deep_equal(highlight_groups(), {
  "MajjitAnsiRed",
  "MajjitAnsiGreen",
  "Bold",
}))

vim.api.nvim_buf_delete(buffer, { force = true })
