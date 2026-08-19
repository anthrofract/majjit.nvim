local M = {}

local VALID_KINDS = {
  action = true,
  menu = true,
  workflow = true,
}

local function canonical_key(key)
  return vim.keycode(key)
end

local function keys_overlap(left, right)
  left = canonical_key(left)
  right = canonical_key(right)
  return left == right or vim.startswith(left, right) or vim.startswith(right, left)
end

local function keys_have_prefix_collision(left, right)
  left = canonical_key(left)
  right = canonical_key(right)
  return left ~= right and (vim.startswith(left, right) or vim.startswith(right, left))
end

local function normalize_keys(value, id)
  if value == false then
    return {}
  end
  if type(value) == "string" then
    value = { value }
  end
  assert(type(value) == "table", ("Command '%s' keys must be a string or list"):format(id))

  local keys = {}
  for _, key in ipairs(value) do
    assert(type(key) == "string" and key ~= "", ("Command '%s' has an invalid key"):format(id))
    for _, existing in ipairs(keys) do
      assert(not keys_overlap(existing, key), ("Command '%s' has overlapping keys '%s' and '%s'"):format(id, existing, key))
    end
    keys[#keys + 1] = key
  end
  return keys
end

local function compile_node(spec, overrides, ids)
  assert(type(spec.id) == "string" and spec.id ~= "", "Command id is required")
  assert(not ids[spec.id], ("Duplicate command id '%s'"):format(spec.id))
  ids[spec.id] = true
  assert(VALID_KINDS[spec.kind], ("Command '%s' has invalid kind '%s'"):format(spec.id, tostring(spec.kind)))
  assert(type(spec.label) == "string" and spec.label ~= "", ("Command '%s' label is required"):format(spec.id))

  local keys = overrides[spec.id]
  if keys == nil then
    keys = spec.keys
  end

  local node = vim.deepcopy(spec)
  node.keys = normalize_keys(keys, spec.id)
  node.children = nil
  node.children_by_key = nil

  if spec.kind == "action" then
    assert(not spec.children, ("Action '%s' cannot have children"):format(spec.id))
    return node
  end

  assert(type(spec.children) == "table" and #spec.children > 0, ("Command '%s' requires children"):format(spec.id))
  if spec.kind == "workflow" then
    assert(type(spec.capture) == "string" and spec.capture ~= "", ("Workflow '%s' capture is required"):format(spec.id))
  end

  node.children = {}
  node.children_by_key = {}
  for _, child_spec in ipairs(spec.children) do
    local child = compile_node(child_spec, overrides, ids)
    node.children[#node.children + 1] = child
    for _, key in ipairs(child.keys) do
      for existing_key, existing in pairs(node.children_by_key) do
        assert(
          not keys_overlap(existing_key, key),
          ("Commands '%s' and '%s' have overlapping sibling keys '%s' and '%s'"):format(
            existing.id,
            child.id,
            existing_key,
            key
          )
        )
      end
      node.children_by_key[key] = child
    end
  end

  return node
end

local function compile_control(spec, overrides, ids)
  assert(type(spec.id) == "string" and spec.id ~= "", "Control id is required")
  assert(not ids[spec.id], ("Duplicate command id '%s'"):format(spec.id))
  ids[spec.id] = true
  assert(type(spec.label) == "string" and spec.label ~= "", ("Control '%s' label is required"):format(spec.id))

  local control = vim.deepcopy(spec)
  local keys = overrides[spec.id]
  if keys == nil then
    keys = spec.keys
  end
  control.keys = normalize_keys(keys, spec.id)
  return control
end

function M.compile(catalog, overrides)
  overrides = overrides or {}
  local ids = { ["commands.root"] = true }
  local root = {
    kind = "menu",
    id = "commands.root",
    label = "Majjit",
    children = {},
    children_by_key = {},
  }

  for _, spec in ipairs(catalog.commands or {}) do
    local child = compile_node(spec, overrides, ids)
    root.children[#root.children + 1] = child
    for _, key in ipairs(child.keys) do
      for existing_key, existing in pairs(root.children_by_key) do
        assert(
          not keys_overlap(existing_key, key),
          ("Root commands '%s' and '%s' have overlapping keys '%s' and '%s'"):format(
            existing.id,
            child.id,
            existing_key,
            key
          )
        )
      end
      root.children_by_key[key] = child
    end
  end

  local controls = {}
  local control_keys = {}
  for name, spec in pairs(catalog.controls or {}) do
    controls[name] = compile_control(spec, overrides, ids)
    for _, key in ipairs(controls[name].keys) do
      for existing_key, existing_name in pairs(control_keys) do
        assert(
          not keys_overlap(existing_key, key),
          ("Controls '%s' and '%s' have overlapping keys '%s' and '%s'"):format(existing_name, name, existing_key, key)
        )
      end
      for root_key in pairs(root.children_by_key) do
        assert(
          not keys_overlap(root_key, key),
          ("Control '%s' key '%s' conflicts with root key '%s'"):format(name, key, root_key)
        )
      end
      control_keys[key] = name
    end
  end

  local function validate_control_keys(node)
    for _, child in ipairs(node.children or {}) do
      for _, key in ipairs(child.keys) do
        for control_key, control_name in pairs(control_keys) do
          assert(
            not keys_overlap(control_key, key),
            ("Control '%s' key '%s' conflicts with command '%s' key '%s'"):format(
              control_name,
              control_key,
              child.id,
              key
            )
          )
        end
      end
      validate_control_keys(child)
    end
  end
  validate_control_keys(root)

  local function validate_root_prefixes(node)
    for _, child in ipairs(node.children or {}) do
      if node ~= root then
        for _, child_key in ipairs(child.keys) do
          for root_key, root_node in pairs(root.children_by_key) do
            assert(
              not keys_have_prefix_collision(root_key, child_key),
              ("Root command '%s' key '%s' conflicts with command '%s' key '%s'"):format(
                root_node.id,
                root_key,
                child.id,
                child_key
              )
            )
          end
        end
      end
      validate_root_prefixes(child)
    end
  end
  validate_root_prefixes(root)

  return {
    controls = controls,
    ids = ids,
    root = root,
  }
end

function M.available(node, context)
  local capabilities = context.capabilities or {}
  for _, capability in ipairs(node.requires or {}) do
    if not capabilities[capability] then
      return false, node.unavailable or ("Requires %s"):format(capability)
    end
  end
  return true, nil
end

function M.help_entries(tree, node, context)
  local entries = {}
  for _, child in ipairs(node.children or {}) do
    if not child.hidden and #child.keys > 0 then
      local available, reason = M.available(child, context)
      entries[#entries + 1] = {
        available = available,
        group = child.group or node.label,
        keys = child.keys,
        label = child.label,
        reason = reason,
      }
    end
  end

  if node == tree.root then
    local help = tree.controls.help
    if help and not help.hidden and #help.keys > 0 then
      entries[#entries + 1] = {
        available = true,
        group = help.group or "General",
        keys = help.keys,
        label = help.label,
      }
    end
  end
  return entries
end

return M
