local M = {}

M.ansi_colors = {
  "Black",
  "Red",
  "Green",
  "Yellow",
  "Blue",
  "Magenta",
  "Cyan",
  "White",
  "BrightBlack",
  "BrightRed",
  "BrightGreen",
  "BrightYellow",
  "BrightBlue",
  "BrightMagenta",
  "BrightCyan",
  "BrightWhite",
}

local ansi_links = {
  "NonText",
  "DiagnosticError",
  "DiagnosticOk",
  "DiagnosticWarn",
  "Function",
  "Keyword",
  "DiagnosticInfo",
  "Normal",
  "NonText",
  "DiagnosticError",
  "DiagnosticOk",
  "DiagnosticWarn",
  "Function",
  "Keyword",
  "DiagnosticInfo",
  "Normal",
}
for index, color in ipairs(M.ansi_colors) do
  vim.api.nvim_set_hl(0, "MajjitAnsi" .. color, {
    default = true,
    link = ansi_links[index],
  })
end

local links = {
  MajjitAnsiBold = "Bold",
  MajjitAnsiUnderline = "Underlined",
  MajjitCursorLine = "CursorLine",
  MajjitDecoration = "Comment",
  MajjitFile = "Directory",
  MajjitLabel = "Function",
  MajjitNormal = "Normal",
  MajjitSelection = "Visual",
  MajjitValue = "String",
}
for group, link in pairs(links) do
  vim.api.nvim_set_hl(0, group, {
    default = true,
    link = link,
  })
end

return M
