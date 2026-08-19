local help_module = require("majjit.commands.help")
local session_module = require("majjit.commands.session")
local tree_module = require("majjit.commands.tree")

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
    kind = "workflow",
    id = "squash.into",
    keys = { "s" },
    group = "Commands",
    label = "Squash into",
    capture = "selection",
    children = {
      {
        kind = "action",
        id = "squash.into.confirm",
        keys = { "<CR>" },
        label = "Use destination",
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
    unavailable = "Requires a file",
  },
}

local tree = tree_module.compile(catalog(commands))
assert(tree.root.children_by_key.d.id == "describe")
assert(tree.root.children_by_key.d.children_by_key.d.id == "describe.inline")

local remapped = tree_module.compile(catalog(commands), { describe = "g" })
assert(remapped.root.children_by_key.g.id == "describe")
assert(remapped.root.children_by_key.d == nil)
assert(tree_module.help_entries(remapped, remapped.root, { capabilities = {} })[1].keys[1] == "g")

expect_error("Duplicate command id", function()
  tree_module.compile(catalog({ commands[1], commands[1] }))
end)
expect_error("overlapping keys", function()
  tree_module.compile(catalog({
    commands[1],
    {
      kind = "action",
      id = "duplicate.key",
      keys = { "d" },
      label = "Duplicate",
    },
  }))
end)
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
expect_error("requires children", function()
  tree_module.compile(catalog({
    {
      kind = "menu",
      id = "empty.menu",
      keys = { "e" },
      label = "Empty",
    },
  }))
end)
expect_error("overlapping keys", function()
  tree_module.compile(catalog({
    {
      kind = "action",
      id = "prefix.short",
      keys = { "z" },
      label = "Short",
    },
    {
      kind = "action",
      id = "prefix.long",
      keys = { "za" },
      label = "Long",
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

local help_entries = tree_module.help_entries(tree, tree.root, { capabilities = {} })
local file_help = vim.iter(help_entries):find(function(entry)
  return entry.label == "File action"
end)
assert(file_help and not file_help.available)
assert(file_help.reason == "Requires a file")

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buffer)
local original_d = function() end
local original_escape = function() end
vim.keymap.set("n", "d", original_d, { buffer = buffer })
vim.keymap.set("n", "<Esc>", original_escape, { buffer = buffer })
local context = {
  capabilities = { commit = true },
  value = "source",
}
local calls = {}
local command_session = session_module.attach({
  actions = {
    ["describe.inline"] = function(action_context)
      calls[#calls + 1] = { id = "describe.inline", context = action_context }
    end,
    ["squash.into.confirm"] = function(action_context, workflow)
      calls[#calls + 1] = {
        id = "squash.into.confirm",
        context = action_context,
        workflow = workflow,
      }
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
  capture = function(_, action_context)
    return { value = action_context.value }
  end,
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

command_session:press("s")
assert(command_session.active.id == "squash.into")
context = {
  capabilities = { commit = true },
  value = "destination",
}
command_session:press("<CR>")
assert(command_session.active == tree.root)
assert(calls[#calls].id == "squash.into.confirm")
assert(calls[#calls].context.value == "destination")
assert(calls[#calls].workflow.source.value == "source")

command_session:press("d")
command_session:press("<Esc>")
assert(command_session.active == tree.root)
assert(command_session.workflow == nil)

context = { capabilities = {} }
local call_count = #calls
command_session:press("f")
assert(#calls == call_count)

command_session:detach()
assert(vim.fn.maparg("d", "n", false, true).callback == original_d)

local missing_capture_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, missing_capture_buffer)
local missing_capture_session = session_module.attach({
  actions = {},
  buffer = missing_capture_buffer,
  get_context = function()
    return { capabilities = { commit = true } }
  end,
  get_window = function()
    return vim.api.nvim_get_current_win()
  end,
  tree = tree,
})
missing_capture_session:press("s")
assert(missing_capture_session.active == tree.root)
assert(missing_capture_session.workflow == nil)
assert(missing_capture_session.help:is_open())
assert(
  table.concat(vim.api.nvim_buf_get_lines(missing_capture_session.help.buffer, 0, -1, false), "\n"):find(
    "No capture handler",
    1,
    true
  )
)
missing_capture_session:detach()

local layout_entries = {}
for i = 1, 18 do
  layout_entries[#layout_entries + 1] = {
    available = i ~= 1,
    group = "Commands",
    keys = i == 1 and { "a", "A" } or { tostring(i) },
    label = "Action " .. i,
    reason = i == 1 and "Unavailable" or nil,
  }
end
layout_entries[#layout_entries + 1] = {
  available = true,
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
assert(not table.concat(layout_lines, "\n"):find("Unavailable", 1, true))
local layout_config = vim.api.nvim_win_get_config(layout_help.window)
assert(layout_config.relative == "editor")
assert(layout_config.width == vim.o.columns)
assert(not layout_config.focusable)
assert(vim.deep_equal(layout_config.border, { "─", "─", "─", "", "", "", "", "" }))
layout_help:close()

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
