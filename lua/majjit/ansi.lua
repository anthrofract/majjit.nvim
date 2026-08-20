local M = {}
local colors = require("majjit.highlights").ansi_colors

local name = "MajjitAnsi"
local namespace = vim.api.nvim_create_namespace(name)
local raw = require("baleia").setup({
  async = false,
  name = name,
})

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
    groups[#groups + 1] = "MajjitAnsiBold"
  end
  if highlight.underline then
    groups[#groups + 1] = "MajjitAnsiUnderline"
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
