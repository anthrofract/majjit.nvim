local M = {}

local VALID_KINDS = {
  action = true,
  menu = true,
}
local CAPABILITY_NAMES = {
  commit = "a commit",
  file = "a file",
  foldable = "a fold",
  repository = "a repository",
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
  assert(type(value) == "table", ("Command '%s' keys must be a list"):format(id))

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

local function add_child(parent, child, scope, overlap)
  parent.children[#parent.children + 1] = child
  for _, key in ipairs(child.keys) do
    for existing_key, existing in pairs(parent.children_by_key) do
      assert(
        not keys_overlap(existing_key, key),
        ("%s '%s' and '%s' have %s '%s' and '%s'"):format(
          scope,
          existing.id,
          child.id,
          overlap,
          existing_key,
          key
        )
      )
    end
    parent.children_by_key[key] = child
  end
end

local function compile_node(spec, ids)
  assert(type(spec.id) == "string" and spec.id ~= "", "Command id is required")
  assert(not ids[spec.id], ("Duplicate command id '%s'"):format(spec.id))
  ids[spec.id] = true
  assert(VALID_KINDS[spec.kind], ("Command '%s' has invalid kind '%s'"):format(spec.id, tostring(spec.kind)))
  assert(type(spec.label) == "string" and spec.label ~= "", ("Command '%s' label is required"):format(spec.id))

  local node = vim.deepcopy(spec)
  node.keys = normalize_keys(spec.keys, spec.id)
  node.children = nil
  node.children_by_key = nil

  if spec.kind == "action" then
    assert(not spec.children, ("Action '%s' cannot have children"):format(spec.id))
    return node
  end

  assert(type(spec.children) == "table" and #spec.children > 0, ("Command '%s' requires children"):format(spec.id))
  node.children = {}
  node.children_by_key = {}
  for _, child_spec in ipairs(spec.children) do
    local child = compile_node(child_spec, ids)
    add_child(node, child, "Commands", "overlapping sibling keys")
  end

  return node
end

local function compile_control(spec, ids)
  assert(type(spec.id) == "string" and spec.id ~= "", "Control id is required")
  assert(not ids[spec.id], ("Duplicate command id '%s'"):format(spec.id))
  ids[spec.id] = true
  assert(type(spec.label) == "string" and spec.label ~= "", ("Control '%s' label is required"):format(spec.id))

  local control = vim.deepcopy(spec)
  control.keys = normalize_keys(spec.keys, spec.id)
  return control
end

function M.compile(catalog)
  local ids = { ["commands.root"] = true }
  local root = {
    kind = "menu",
    id = "commands.root",
    label = "Majjit",
    children = {},
    children_by_key = {},
  }

  for _, spec in ipairs(catalog.commands or {}) do
    local child = compile_node(spec, ids)
    add_child(root, child, "Root commands", "overlapping keys")
  end

  local controls = {}
  local control_keys = {}
  for name, spec in pairs(catalog.controls or {}) do
    controls[name] = compile_control(spec, ids)
    for _, key in ipairs(controls[name].keys) do
      for existing_key, existing_name in pairs(control_keys) do
        assert(
          not keys_overlap(existing_key, key),
          ("Controls '%s' and '%s' have overlapping keys '%s' and '%s'"):format(existing_name, name, existing_key, key)
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
    root = root,
  }
end

function M.available(node, context)
  local capabilities = context.capabilities or {}
  for _, capability in ipairs(node.requires or {}) do
    if not capabilities[capability] then
      return false, ("Requires %s"):format(CAPABILITY_NAMES[capability] or capability)
    end
  end
  return true, nil
end

function M.help_entries(tree, node)
  local entries = {}
  for _, child in ipairs(node.children or {}) do
    if not child.hidden and #child.keys > 0 then
      entries[#entries + 1] = {
        group = child.group or node.label,
        keys = child.keys,
        label = child.label,
      }
    end
  end

  if node == tree.root then
    local help = tree.controls.help
    if help and not help.hidden and #help.keys > 0 then
      entries[#entries + 1] = {
        group = help.group or "General",
        keys = help.keys,
        label = help.label,
      }
    end
  end
  return entries
end

return M
