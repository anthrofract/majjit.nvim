local operation_module = require("majjit.operation")

local sync_result
operation_module.new(function(operation)
  local value, err = operation:await(function(callback)
    callback(nil, "failed")
    return { kill = function() end }
  end)
  assert(value == nil and err == "failed")
  return "completed"
end, function(value, err)
  assert(not err)
  sync_result = value
end)
assert(sync_result == "completed")

local resume
local async_result
operation_module.new(function(operation)
  return operation:await(function(callback)
    resume = callback
    return { kill = function() end }
  end)
end, function(value, err)
  assert(not err)
  async_result = value
end)
assert(async_result == nil)
resume("completed")
assert(async_result == "completed")

local killed = false
local completed = false
local late_callback
local cancelled = operation_module.new(function(operation)
  return operation:await(function(callback)
    late_callback = callback
    return {
      kill = function()
        killed = true
      end,
    }
  end)
end, function()
  completed = true
end)
cancelled:cancel()
late_callback("too late")
assert(killed)
assert(not completed)
