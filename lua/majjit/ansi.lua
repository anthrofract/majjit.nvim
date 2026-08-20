local M = {}

local name = "MajjitAnsi"
local namespace = vim.api.nvim_create_namespace(name)
local raw = require("baleia").setup({
  async = false,
  name = name,
})

local colors = {
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
local links = {
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
for index, color in ipairs(colors) do
  vim.api.nvim_set_hl(0, "MajjitAnsi" .. color, {
    default = true,
    link = links[index],
  })
end

local translations = {}

local function translate(group)
  if translations[group] then
    return translations[group]
  end

  local highlight = vim.api.nvim_get_hl(0, { link = false, name = group })
  local groups = {}
  if highlight.ctermfg and colors[highlight.ctermfg + 1] then
    groups[#groups + 1] = "MajjitAnsi" .. colors[highlight.ctermfg + 1]
  end
  if highlight.bold then
    groups[#groups + 1] = "Bold"
  end
  if highlight.italic then
    groups[#groups + 1] = "Italic"
  end
  if
    highlight.underline
    or highlight.undercurl
    or highlight.underdouble
    or highlight.underdotted
    or highlight.underdashed
  then
    groups[#groups + 1] = "Underlined"
  end
  if highlight.strikethrough then
    groups[#groups + 1] = "Strike"
  end
  if highlight.reverse then
    groups[#groups + 1] = "Visual"
  end
  translations[group] = groups
  return groups
end

function M.once(buffer)
  raw.once(buffer)
  local extmarks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local id, row, column, details = unpack(extmark)
    local groups = details.hl_group and translate(details.hl_group) or {}
    if #groups > 0 then
      vim.api.nvim_buf_set_extmark(buffer, namespace, row, column, {
        end_col = details.end_col,
        end_row = details.end_row,
        hl_group = groups,
        id = id,
      })
    end
  end
end

return M
