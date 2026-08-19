local M = {}

local Operation = {}
Operation.__index = Operation

local function pack(...)
  return { n = select("#", ...), ... }
end

function M.new(fn, callback)
  local operation = setmetatable({
    callback = callback,
    cancelled = false,
    process = nil,
  }, Operation)

  operation.thread = coroutine.create(function()
    return fn(operation)
  end)
  operation:_resume()
  return operation
end

function Operation:_resume(...)
  if self.cancelled then
    return
  end
  local ok, value, err = coroutine.resume(self.thread, ...)
  if not ok then
    self.cancelled = true
    self.callback(nil, value)
  elseif coroutine.status(self.thread) == "dead" then
    self.cancelled = true
    self.process = nil
    self.callback(value, err)
  end
end

function Operation:await(start)
  local pending
  local waiting = false
  self.process = start(function(...)
    if self.cancelled then
      return
    end
    if waiting then
      self:_resume(...)
    else
      pending = pack(...)
    end
  end)
  if pending then
    self.process = nil
    return unpack(pending, 1, pending.n)
  end
  waiting = true
  local values = pack(coroutine.yield())
  self.process = nil
  return unpack(values, 1, values.n)
end

function Operation:cancel()
  if self.cancelled then
    return
  end
  self.cancelled = true
  if self.process then
    pcall(self.process.kill, self.process, 15)
    self.process = nil
  end
  if self.on_cancel then
    self.on_cancel()
  end
end

Operation.kill = Operation.cancel

return M
