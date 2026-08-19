local help_module = require("majjit.commands.help")
local output_module = require("majjit.commands.output")
local prompt_module = require("majjit.commands.prompt")
local session_module = require("majjit.commands.session")
local tree_module = require("majjit.commands.tree")

tree_module.compile(require("majjit.commands.catalog"))
local function expect_error(pattern, callback)
  local ok, err = pcall(callback)
  assert(not ok, "Expected callback to fail")
  assert(tostring(err):match(pattern), tostring(err))
end

local function catalog(commands)
  return {
    controls = {
      cancel = {
        id = "commands.cancel",
        keys = { "<Esc>" },
        hidden = true,
        label = "Cancel",
      },
      help = {
        id = "commands.help",
        keys = { "?" },
        group = "General",
        label = "Help",
      },
    },
    commands = commands,
  }
end

local commands = {
  {
    kind = "menu",
    id = "describe",
    keys = { "d" },
    group = "Commands",
    label = "Describe",
    children = {
      {
        kind = "action",
        id = "describe.inline",
        keys = { "d" },
        label = "Selection",
        requires = { "commit" },
      },
    },
  },
  {
    kind = "action",
    id = "view.preserve",
    keys = { "x" },
    group = "General",
    label = "Preserve session",
    available_during_session = true,
    preserve_session = true,
  },
  {
    kind = "action",
    id = "view.other",
    keys = { "y" },
    group = "General",
    label = "Other action",
  },
  {
    kind = "action",
    id = "view.file",
    keys = { "f" },
    group = "General",
    label = "File action",
    requires = { "file" },
  },
}

local tree = tree_module.compile(catalog(commands))
expect_error("overlapping keys", function()
  tree_module.compile(catalog({
    {
      kind = "action",
      id = "alias.tab",
      keys = { "<Tab>" },
      label = "Tab",
    },
    {
      kind = "action",
      id = "alias.control-i",
      keys = { "<C-I>" },
      label = "Control I",
    },
  }))
end)
expect_error("Root command.*conflicts", function()
  tree_module.compile(catalog({
    {
      kind = "action",
      id = "root.z",
      keys = { "z" },
      label = "Root Z",
    },
    {
      kind = "menu",
      id = "nested.menu",
      keys = { "n" },
      label = "Nested",
      children = {
        {
          kind = "action",
          id = "nested.za",
          keys = { "za" },
          label = "Nested ZA",
        },
      },
    },
  }))
end)
expect_error("conflicts with command", function()
  tree_module.compile(catalog({
    {
      kind = "menu",
      id = "help.conflict",
      keys = { "h" },
      label = "Conflict",
      children = {
        {
          kind = "action",
          id = "help.conflict.child",
          keys = { "?" },
          label = "Conflict child",
        },
      },
    },
  }))
end)

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buffer)
local original_d = function() end
local original_escape = function() end
vim.keymap.set("n", "d", original_d, { buffer = buffer })
vim.keymap.set("n", "<Esc>", original_escape, { buffer = buffer })
local context = {
  capabilities = { commit = true },
}
local calls = {}
local command_session = session_module.attach({
  actions = {
    ["describe.inline"] = function(action_context)
      calls[#calls + 1] = { id = "describe.inline", context = action_context }
    end,
    ["view.file"] = function()
      error("Unavailable action ran")
    end,
    ["view.other"] = function()
      calls[#calls + 1] = { id = "view.other" }
    end,
    ["view.preserve"] = function()
      calls[#calls + 1] = { id = "view.preserve" }
    end,
  },
  buffer = buffer,
  get_context = function()
    return context
  end,
  get_window = function()
    return vim.api.nvim_get_current_win()
  end,
  tree = tree,
})

assert(vim.fn.maparg("d", "n", false, true).buffer == 1)
assert(vim.fn.maparg("j", "n", false, true).buffer ~= 1)

command_session:press("?")
assert(command_session.help:is_open())
command_session:press("<Esc>")
assert(not command_session.help:is_open())
assert(vim.fn.maparg("<Esc>", "n", false, true).callback == original_escape)

command_session:press("d")
assert(command_session.active.id == "describe")
assert(command_session.help:is_open())
command_session:press("y")
assert(command_session.active.id == "describe")
local help_buffer = command_session.help.buffer
assert(table.concat(vim.api.nvim_buf_get_lines(help_buffer, 0, -1, false), "\n"):find("Unbound suffix: y", 1, true))
command_session:press("x")
assert(command_session.active.id == "describe")
assert(calls[#calls].id == "view.preserve")
command_session:press("d")
assert(command_session.active == tree.root)
assert(calls[#calls].id == "describe.inline")

command_session:press("d")
command_session:press("<Esc>")
assert(command_session.active == tree.root)

context = { capabilities = {} }
local call_count = #calls
command_session:press("f")
assert(#calls == call_count)

command_session:detach()
assert(vim.fn.maparg("d", "n", false, true).callback == original_d)

local layout_entries = {}
for i = 1, 18 do
  layout_entries[#layout_entries + 1] = {
    group = "Commands",
    keys = i == 1 and { "a", "A" } or { tostring(i) },
    label = "Action " .. i,
  }
end
layout_entries[#layout_entries + 1] = {
  group = "General",
  keys = { "q" },
  label = "Close",
}

local layout_help = help_module.new(function()
  return vim.api.nvim_get_current_win()
end)
layout_help:show(layout_entries)
local layout_lines = vim.api.nvim_buf_get_lines(layout_help.buffer, 0, -1, false)
assert(#layout_lines == 19)
assert(layout_lines[#layout_lines] == "")
assert(layout_lines[1]:find("Commands", 1, true))
assert(layout_lines[1]:find("General", 1, true))
assert(layout_lines[2]:find("a/A Action 1", 1, true))
assert(layout_lines[2]:find("18 Action 18", 1, true))
assert(layout_lines[2]:find("q Close", 1, true))
local layout_config = vim.api.nvim_win_get_config(layout_help.window)
assert(layout_config.relative == "editor")
assert(layout_config.width == vim.o.columns)
assert(not layout_config.focusable)
assert(vim.deep_equal(layout_config.border, { "─", "─", "─", "", "", "", "", "" }))
layout_help:close()

local command_output = output_module.new(function()
  return vim.api.nvim_get_current_win()
end, {
  once = function() end,
})
command_output:start_sequence()
command_output:start_command({ "git", "fetch" })
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(command_output.buffer, 0, -1, false), {
  "❯ jj git fetch",
  "",
  "Running...",
  "",
}))
command_output:finish_command({ code = 0, stderr = "Fetched remote\n" })
command_output:start_command({ "new", "trunk()" })
command_output:finish_command({ code = 0, stderr = "Working copy updated\nParent updated\n" })
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(command_output.buffer, 0, -1, false), {
  "❯ jj git fetch",
  "",
  "Fetched remote",
  "",
  "❯ jj new trunk()",
  "",
  "Working copy updated",
  "Parent updated",
  "",
}))
local output_config = vim.api.nvim_win_get_config(command_output.window)
assert(output_config.relative == "editor")
assert(output_config.width == vim.o.columns)
assert(not output_config.focusable)
command_output:hide()
assert(not command_output:is_open())
assert(command_output:show())
assert(command_output:is_open())
local long_output = {}
for i = 1, vim.o.lines + 10 do
  long_output[#long_output + 1] = "Line " .. i
end
command_output:start_sequence()
command_output:start_command({ "log" })
command_output:finish_command({ code = 0, stderr = table.concat(long_output, "\n") })
assert(vim.api.nvim_win_get_cursor(command_output.window)[1] == vim.api.nvim_buf_line_count(command_output.buffer))
local command_output_buffer = command_output.buffer
command_output:close()
assert(not vim.api.nvim_buf_is_valid(command_output_buffer))

local prompt_output = {
  open = true,
  show_count = 0,
}
function prompt_output:is_open()
  return self.open
end
function prompt_output:has_output()
  return true
end
function prompt_output:hide()
  self.open = false
end
function prompt_output:show()
  self.open = true
  self.show_count = self.show_count + 1
end
local prompt = prompt_module.new({
  get_buffer = function()
    return vim.api.nvim_get_current_buf()
  end,
  output = prompt_output,
  update_mappings = function() end,
})
local original_select = vim.ui.select
local original_input = vim.ui.input
local selected_value
vim.ui.select = function(items, opts, callback)
  assert(vim.deep_equal(items, { "candidate" }))
  assert(opts.prompt == "Select: ")
  callback(items[1])
end
prompt:select({
  load = function(callback)
    callback({ "candidate" }, nil)
  end,
  prompt = "Select: ",
}, function(value)
  selected_value = value
end)
assert(selected_value == "candidate")
assert(not prompt_output.open)

prompt_output.open = true
local input_value
vim.ui.input = function(opts, callback)
  assert(opts.prompt == "Manual: ")
  callback("  manual  ")
end
prompt:select({
  input_prompt = "Manual: ",
  load = function(callback)
    callback({}, nil)
  end,
  prompt = "Select: ",
}, function(value)
  input_value = value
end)
assert(input_value == "manual")
assert(not prompt_output.open)

prompt_output.open = true
vim.ui.input = function(_, callback)
  callback(nil)
end
prompt:input({ prompt = "Cancel: " }, function()
  error("Cancelled input ran")
end)
assert(prompt_output.open)
assert(prompt_output.show_count == 1)

local input_called = false
local original_notify = vim.notify
vim.notify = function() end
local blocked_prompt = prompt_module.new({
  can_start = function()
    return false
  end,
  get_buffer = function()
    return vim.api.nvim_get_current_buf()
  end,
  output = prompt_output,
  update_mappings = function() end,
})
vim.ui.input = function()
  input_called = true
end
blocked_prompt:input({ prompt = "Blocked: " }, function() end)
assert(not input_called)
assert(prompt_output.open)
vim.notify = original_notify
vim.ui.select = original_select
vim.ui.input = original_input

local leave_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, leave_buffer)
local overlay = {
  open = true,
  show_count = 0,
}
function overlay:is_open()
  return self.open
end
function overlay:hide()
  self.open = false
end
function overlay:show()
  self.open = true
  self.show_count = self.show_count + 1
end
local leave_session = session_module.attach({
  actions = {},
  buffer = leave_buffer,
  get_context = function()
    return { capabilities = {} }
  end,
  get_window = function()
    return vim.api.nvim_get_current_win()
  end,
  overlay = overlay,
  tree = tree_module.compile(catalog({})),
})
leave_session:press("?")
assert(not overlay.open)
vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
assert(not overlay.open)
assert(overlay.show_count == 0)
leave_session:detach()

local lifecycle_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, lifecycle_buffer)
local lifecycle_session = session_module.attach({
  actions = {},
  buffer = lifecycle_buffer,
  get_context = function()
    return { capabilities = {} }
  end,
  get_window = function()
    return vim.api.nvim_get_current_win()
  end,
  tree = tree_module.compile(catalog({})),
})
lifecycle_session:press("?")
local lifecycle_help = lifecycle_session.help.buffer
assert(vim.api.nvim_buf_is_valid(lifecycle_help))
vim.api.nvim_buf_delete(lifecycle_buffer, { force = true })
assert(lifecycle_session.detached)
assert(not vim.api.nvim_buf_is_valid(lifecycle_help))
