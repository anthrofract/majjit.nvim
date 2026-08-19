vim.api.nvim_create_user_command("Majjit", function()
  print("majjit.nvim loaded!")
end, {
  desc = "Open Majjit",
})
