local help = require("majjit.commands.help")
local tree_module = require("majjit.commands.tree")

local M = {}

local Session = {}
Session.__index = Session

local function contains(values, target)
  for _, value in ipairs(values or {}) do
    if value == target then
      return true
    end
  end
  return false
end

local function restore_mapping(buffer, key, mapping)
  if not mapping then
    return
  end
  local rhs = type(mapping.callback) == "function" and mapping.callback or mapping.rhs
  vim.keymap.set("n", key, rhs, {
    buffer = buffer,
    desc = mapping.desc,
    expr = mapping.expr == 1,
    nowait = mapping.nowait == 1,
    remap = mapping.noremap == 0,
    silent = mapping.silent == 1,
  })
end

function M.attach(opts)
  local session = setmetatable({
    actions = opts.actions,
    active = opts.tree.root,
    autocmd_group = vim.api.nvim_create_augroup("majjit-commands-" .. opts.buffer, { clear = true }),
    buffer = opts.buffer,
    capture = opts.capture,
    captured_keys = {},
    detached = false,
    displaced_mappings = {},
    error_message = nil,
    get_context = opts.get_context,
    help = help.new(opts.get_window),
    installed_keys = {},
    tree = opts.tree,
    workflow = nil,
  }, Session)

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = opts.buffer,
    group = session.autocmd_group,
    callback = function()
      if session.help:is_open() then
        session:show_help()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = opts.buffer,
    group = session.autocmd_group,
    callback = function()
      session:cancel()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = opts.buffer,
    group = session.autocmd_group,
    callback = function()
      session:detach()
    end,
  })

  session:_apply_mappings()
  return session
end

function Session:_clear_mappings()
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    self.installed_keys = {}
    return
  end
  for key in pairs(self.installed_keys) do
    pcall(vim.keymap.del, "n", key, { buffer = self.buffer })
    restore_mapping(self.buffer, key, self.displaced_mappings[key])
  end
  self.installed_keys = {}
end

function Session:_map(key, description)
  if not self.captured_keys[key] then
    local mapping = vim.fn.maparg(key, "n", false, true)
    self.displaced_mappings[key] = not vim.tbl_isempty(mapping) and mapping or nil
    self.captured_keys[key] = true
  end
  vim.keymap.set("n", key, function()
    self:press(key)
  end, {
    buffer = self.buffer,
    desc = description,
    nowait = true,
  })
  self.installed_keys[key] = true
end

function Session:_apply_mappings()
  if self.detached or not vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  self:_clear_mappings()

  if self.active == self.tree.root then
    for _, node in ipairs(self.tree.root.children) do
      for _, key in ipairs(node.keys) do
        self:_map(key, node.label)
      end
    end
  else
    for _, node in ipairs(self.tree.root.children) do
      for _, key in ipairs(node.keys) do
        self:_map(key, node.available_during_session and node.label or "Invalid Majjit command key")
      end
    end
    for _, node in ipairs(self.active.children) do
      for _, key in ipairs(node.keys) do
        self:_map(key, node.label)
      end
    end
  end

  for _, key in ipairs(self.tree.controls.help.keys) do
    self:_map(key, self.tree.controls.help.label)
  end
  if self.active ~= self.tree.root or self.help:is_open() then
    for _, key in ipairs(self.tree.controls.cancel.keys) do
      self:_map(key, self.tree.controls.cancel.label)
    end
  end
end

function Session:_context()
  local context = self.get_context() or {}
  context.capabilities = context.capabilities or {}
  return context
end

function Session:_render_help()
  local was_open = self.help:is_open()
  self.help:show(tree_module.help_entries(self.tree, self.active, self:_context()), self.error_message)
  if not was_open then
    self:_apply_mappings()
  end
end

function Session:show_help()
  self.error_message = nil
  self:_render_help()
end

function Session:update_help()
  if self.help:is_open() then
    self:_render_help()
  end
end

function Session:_show_error(message)
  self.error_message = message
  self:_render_help()
end

function Session:_reset()
  self.active = self.tree.root
  self.error_message = nil
  self.workflow = nil
  self.help:close()
  self:_apply_mappings()
end

function Session:cancel()
  if self.detached then
    return
  end
  self:_reset()
end

function Session:_activate(node)
  local context = self:_context()
  local available, reason = tree_module.available(node, context)
  if not available then
    if self.help:is_open() or self.active ~= self.tree.root then
      self:_show_error(reason)
    end
    return
  end

  if node.kind == "menu" or node.kind == "workflow" then
    if node.kind == "workflow" then
      if not self.capture then
        self:_show_error(("No capture handler for workflow '%s'"):format(node.id))
        return
      end
      local source, capture_error = self.capture(node.capture, context)
      if not source then
        self:_show_error(capture_error or "Cannot capture selection")
        return
      end
      self.workflow = {
        id = node.id,
        source = source,
      }
    end
    self.active = node
    self.error_message = nil
    self:_apply_mappings()
    self:show_help()
    return
  end

  local action = self.actions[node.id]
  assert(action, ("No action registered for command '%s'"):format(node.id))
  local workflow = self.workflow
  if not node.preserve_session then
    self:_reset()
  end
  local ok, err = pcall(action, context, workflow)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Majjit" })
  end
  if node.preserve_session and not self.detached then
    self:update_help()
  end
end

function Session:press(key)
  if self.detached then
    return
  end
  if contains(self.tree.controls.help.keys, key) then
    self:show_help()
    return
  end
  if contains(self.tree.controls.cancel.keys, key) then
    self:cancel()
    return
  end

  local node = self.active.children_by_key[key]
  if node then
    self:_activate(node)
    return
  end

  if self.active ~= self.tree.root then
    local root_node = self.tree.root.children_by_key[key]
    if root_node and root_node.available_during_session then
      if not root_node.preserve_session then
        self:_reset()
      end
      self:_activate(root_node)
      return
    end
    self:_show_error("Unbound suffix: " .. key)
  end
end

function Session:detach()
  if self.detached then
    return
  end
  self.detached = true
  self:_clear_mappings()
  self.help:close()
  pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
end

return M
