vim.api.nvim_create_user_command("Majjit", function()
  require("majjit").open()
end, {
  desc = "Open Majjit",
})
