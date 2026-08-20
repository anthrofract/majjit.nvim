local M = {}

function M.split(value)
  local words = {}
  local word = {}
  local quote
  local escaped = false
  local started = false

  local function finish()
    if started then
      words[#words + 1] = table.concat(word)
      word = {}
      started = false
    end
  end

  for index = 1, #value do
    local char = value:sub(index, index)
    if escaped then
      word[#word + 1] = char
      escaped = false
      started = true
    elseif char == "\\" and quote ~= "'" then
      escaped = true
      started = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        word[#word + 1] = char
      end
      started = true
    elseif char == "'" or char == '"' then
      quote = char
      started = true
    elseif char:match("%s") then
      finish()
    else
      word[#word + 1] = char
      started = true
    end
  end

  if escaped then
    return nil, "Trailing escape"
  end
  if quote then
    return nil, "Unterminated quote"
  end
  finish()
  return words
end

return M
