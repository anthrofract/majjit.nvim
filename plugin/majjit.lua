vim.api.nvim_create_user_command("Majjit", function()
  require("majjit.main").open()
end, {
  desc = "Open Majjit",
})
