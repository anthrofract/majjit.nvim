local jj = require("majjit.jj")
local shellwords = require("majjit.shellwords")

local M = {}

local function change_id(context)
  return context.commit.change_id
end

local function file_path(context)
  return context.file and context.file.path
end

local function source_id(context)
  return context.source.commit.change_id
end

local function source_path(context)
  return context.source.file and context.source.file.path
end

local function parse_args(value)
  local args, err = shellwords.split(value)
  if not args then
    vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
  end
  return args
end

function M.new(workflow, close)
  local actions = {}

  local function mutate(context, command, selection, append_output)
    workflow:mutate(context, command, selection, append_output)
  end

  local function input_command(context, prompt, build, default)
    workflow:input(prompt, function(value)
      local command = build(value)
      if command then
        mutate(context, command)
      end
    end, default)
  end

  local function select_values(context, prompt, query, callback, opts)
    workflow:select_values(context.root, prompt, query, function(value, append_output, selection_err)
      if selection_err then
        vim.notify(selection_err, vim.log.levels.WARN, { title = "Majjit" })
        return
      end
      if value then
        callback(value, append_output)
      end
    end, opts)
  end

  actions["revision.absorb.selection"] = function(context)
    mutate(context, jj.absorb(change_id(context), nil, file_path(context)))
  end
  actions["revision.absorb.into.destination"] = function(context)
    mutate(context, jj.absorb(source_id(context), change_id(context), source_path(context)))
  end

  actions["bookmark.advance"] = function(context)
    mutate(context, jj.bookmark_advance(change_id(context)))
  end
  actions["bookmark.create"] = function(context)
    input_command(context, "Bookmark name: ", function(name)
      return jj.bookmark_create(name, change_id(context))
    end)
  end
  local bookmark_lists = {
    ["bookmark.list.all"] = jj.bookmark_display_names,
    ["bookmark.list.conflicted"] = jj.bookmark_conflicted_names,
    ["bookmark.list.local"] = jj.bookmark_local_names,
    ["bookmark.list.tracked"] = function(root, callback)
      jj.bookmark_remote_names(root, true, function(values, err)
        if values then
          values = vim.tbl_map(function(value)
            return value.name .. "@" .. value.remote
          end, values)
        end
        callback(values, err)
      end)
    end,
    ["bookmark.list.untracked"] = function(root, callback)
      jj.bookmark_remote_names(root, false, function(values, err)
        if values then
          values = vim.tbl_map(function(value)
            return value.name .. "@" .. value.remote
          end, values)
        end
        callback(values, err)
      end)
    end,
  }
  for id, query in pairs(bookmark_lists) do
    actions[id] = function(context)
      select_values(context, "Bookmarks: ", function(callback)
        return query(context.root, callback)
      end, function() end, { allow_custom = false })
    end
  end
  actions["bookmark.move.selection.destination"] = function(context)
    mutate(context, jj.bookmark_move(source_id(context), change_id(context), false))
  end
  actions["bookmark.move.allow_backwards.destination"] = function(context)
    mutate(context, jj.bookmark_move(source_id(context), change_id(context), true))
  end
  actions["bookmark.rename"] = function(context)
    select_values(context, "Rename bookmark: ", function(callback)
      return jj.bookmark_local_names(context.root, callback)
    end, function(old_name)
      workflow:input("New bookmark name: ", function(new_name)
        if new_name ~= old_name then
          mutate(context, jj.bookmark_rename(old_name, new_name))
        end
      end, old_name)
    end, { allow_custom = false })
  end
  local function select_remote_bookmark(context, tracked, prompt, build)
    select_values(context, prompt, function(callback)
      return jj.bookmark_remote_names(context.root, tracked, callback)
    end, function(value)
      mutate(context, build(value.name, value.remote))
    end, {
      allow_custom = false,
      format_item = function(value)
        return value.name .. "@" .. value.remote
      end,
    })
  end
  actions["bookmark.track"] = function(context)
    select_remote_bookmark(context, false, "Track bookmark: ", jj.bookmark_track)
  end
  actions["bookmark.untrack"] = function(context)
    select_remote_bookmark(context, true, "Untrack bookmark: ", jj.bookmark_untrack)
  end
  local function select_bookmark_mutation(context, prompt, build)
    select_values(context, prompt, function(callback)
      return jj.bookmark_names(context.root, callback)
    end, function(name)
      mutate(context, build(name))
    end, { allow_custom = false })
  end
  actions["bookmark.delete"] = function(context)
    select_bookmark_mutation(context, "Delete bookmark: ", jj.bookmark_delete)
  end
  actions["bookmark.forget"] = function(context)
    select_bookmark_mutation(context, "Forget bookmark: ", function(name)
      return jj.bookmark_forget(name, false)
    end)
  end
  actions["bookmark.forget_remotes"] = function(context)
    select_bookmark_mutation(context, "Forget bookmark and remotes: ", function(name)
      return jj.bookmark_forget(name, true)
    end)
  end
  local function set_bookmark(context, allow_backwards)
    select_values(context, "Set bookmark: ", function(callback)
      return jj.bookmark_local_names(context.root, callback)
    end, function(name)
      mutate(context, jj.bookmark_set(name, change_id(context), allow_backwards))
    end, { manual = "Enter manually...", input_prompt = "Bookmark name: " })
  end
  actions["bookmark.set"] = function(context)
    set_bookmark(context, false)
  end
  actions["bookmark.set_allow_backwards"] = function(context)
    set_bookmark(context, true)
  end

  actions["commands.custom"] = function(context)
    workflow:input("Jj args: ", function(value)
      local args = parse_args(value)
      if args and #args > 0 then
        mutate(context, jj.custom(args))
      end
    end)
  end

  actions["revision.commit.selection"] = function(context)
    workflow:commit(context, false)
  end
  actions["revision.commit.edit"] = function(context)
    workflow:commit(context, true)
  end

  actions["revision.duplicate.selection"] = function(context)
    mutate(context, jj.duplicate(change_id(context)))
  end
  local duplicate_destinations = {
    after = "--insert-after",
    before = "--insert-before",
    onto = "--onto",
  }
  for kind, flag in pairs(duplicate_destinations) do
    actions["revision.duplicate." .. kind .. ".destination"] = function(context)
      mutate(context, jj.duplicate(source_id(context), flag, change_id(context)))
    end
  end

  actions["file.track"] = function(context)
    input_command(context, "Filepath: ", jj.file_track)
  end
  actions["file.untrack"] = function(context)
    mutate(context, jj.file_untrack(file_path(context)))
  end

  local metaedit = {
    ["revision.metaedit.force_rewrite"] = "--force-rewrite",
    ["revision.metaedit.update_author"] = "--update-author",
    ["revision.metaedit.update_author_timestamp"] = "--update-author-timestamp",
    ["revision.metaedit.update_change_id"] = "--update-change-id",
  }
  for id, flag in pairs(metaedit) do
    actions[id] = function(context)
      mutate(context, jj.author(change_id(context), flag))
    end
  end
  local function set_author_metadata(context, field)
    workflow:query(context.root, function(callback)
      return jj.author_metadata(context.root, change_id(context), callback)
    end, function(metadata, err)
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
        return
      end
      local prompt = field == "author" and "Author: " or "Author timestamp: "
      local default = field == "author" and (metadata.name .. " <" .. metadata.email .. ">") or metadata.timestamp
      workflow:input(prompt, function(value)
        local command = field == "author" and jj.set_author(change_id(context), value)
          or jj.set_author_timestamp(change_id(context), value)
        mutate(context, command)
      end, default)
    end)
  end
  actions["revision.metaedit.set_author"] = function(context)
    set_author_metadata(context, "author")
  end
  actions["revision.metaedit.set_author_timestamp"] = function(context)
    set_author_metadata(context, "timestamp")
  end

  local revsets = {
    ["log.revset.all"] = "all()",
    ["log.revset.bookmarks"] = "bookmarks() | remote_bookmarks() | tags() | remote_tags()",
    ["log.revset.conflicts"] = "conflicts()",
    ["log.revset.default"] = require("majjit.repository").DEFAULT_REVSET,
    ["log.revset.mine"] = "mine()",
    ["log.revset.mutable"] = "mutable()",
    ["log.revset.recent"] = 'committer_date(after:"1 week ago")',
    ["log.revset.stack"] = "trunk() | (trunk()..@)::",
    ["log.revset.working_copy_ancestry"] = "::@",
  }
  for id, revset in pairs(revsets) do
    actions[id] = function(context)
      workflow:set_revset(context.root, revset)
    end
  end
  actions["log.revset.custom"] = function(context)
    workflow:input("Revset: ", function(revset)
      workflow:set_revset(context.root, revset)
    end, context.revset)
  end
  actions["log.revset.jj_default"] = function(context)
    workflow:query(context.root, function(callback)
      return jj.config_log_revset(context.root, callback)
    end, function(revset, err)
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
      else
        workflow:set_revset(context.root, revset)
      end
    end)
  end

  local function navigate(context, direction, mode, nth)
    local function run(offset)
      mutate(context, jj.next_prev(direction, mode, offset), true)
    end
    if not nth then
      run()
      return
    end
    if vim.v.count > 0 then
      run(vim.v.count)
      return
    end
    workflow:input("Offset: ", function(value)
      local offset = tonumber(value)
      if not offset or offset < 1 or offset % 1 ~= 0 then
        vim.notify("Offset must be a positive integer", vim.log.levels.ERROR, { title = "Majjit" })
        return
      end
      run(offset)
    end)
  end
  local navigation = {
    conflict = { "--conflict", false },
    default = { nil, false },
    edit = { "--edit", false },
    no_edit = { "--no-edit", false },
    nth = { nil, true },
    nth_edit = { "--edit", true },
    nth_no_edit = { "--no-edit", true },
  }
  for _, direction in ipairs({ "next", "previous" }) do
    local command = direction == "previous" and "prev" or "next"
    for suffix, spec in pairs(navigation) do
      actions["navigation." .. direction .. "." .. suffix] = function(context)
        navigate(context, command, spec[1], spec[2])
      end
    end
  end

  actions["revision.parallelize.selection"] = function(context)
    local id = change_id(context)
    mutate(context, jj.parallelize(id .. "-::" .. id))
  end
  actions["revision.parallelize.range.destination"] = function(context)
    mutate(context, jj.parallelize(source_id(context) .. "::" .. change_id(context)))
  end
  actions["revision.parallelize.revset"] = function(context)
    input_command(context, "Revset: ", jj.parallelize)
  end

  actions["revision.squash.parent"] = function(context)
    workflow:query(context.root, function(callback)
      return jj.parent_descriptions(context.root, change_id(context), callback)
    end, function(parents, err)
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
        return
      end
      if #parents ~= 1 then
        vim.notify("Squashing into a parent requires exactly one parent", vim.log.levels.ERROR, { title = "Majjit" })
        return
      end
      mutate(
        context,
        jj.squash(change_id(context), file_path(context), true),
        { change_id = parents[1].change_id }
      )
    end)
  end
  actions["revision.squash.parent_edit"] = function(context)
    workflow:squash_edit(context)
  end
  actions["revision.squash.into.destination"] = function(context)
    mutate(
      context,
      jj.squash_into(source_id(context), change_id(context), source_path(context), true),
      { change_id = change_id(context) }
    )
  end
  actions["revision.squash.into_edit.destination"] = function(context)
    workflow:squash_edit(context, context.commit)
  end

  actions["repository.status"] = function(context)
    workflow:run(context, jj.status())
  end

  actions["revision.sign.selection"] = function(context)
    mutate(context, jj.sign(change_id(context)))
  end
  actions["revision.sign.range.destination"] = function(context)
    mutate(context, jj.sign(source_id(context) .. "::" .. change_id(context)))
  end
  actions["revision.unsign.selection"] = function(context)
    mutate(context, jj.unsign(change_id(context)))
  end
  actions["revision.unsign.range.destination"] = function(context)
    mutate(context, jj.unsign(source_id(context) .. "::" .. change_id(context)))
  end
  actions["revision.simplify_parents.selection"] = function(context)
    mutate(context, jj.simplify_parents(change_id(context), "--revision"))
  end
  actions["revision.simplify_parents.descendants"] = function(context)
    mutate(context, jj.simplify_parents(change_id(context), "--source"))
  end

  actions["revision.rebase.branch.trunk"] = function(context)
    mutate(context, jj.rebase("--branch", change_id(context), "--onto", "trunk()"))
  end
  actions["revision.rebase.branch.trunk_sync"] = function(context)
    mutate(context, { jj.git_fetch(), jj.rebase("--branch", change_id(context), "--onto", "trunk()") })
  end
  actions["revision.rebase.custom"] = function(context)
    workflow:input("Rebase args: ", function(value)
      local args = parse_args(value)
      if args then
        table.insert(args, 1, "rebase")
        mutate(context, jj.custom(args))
      end
    end)
  end
  local source_flags = { branch = "--branch", revision = "--revisions", source = "--source" }
  local placement_flags = { after = "--insert-after", before = "--insert-before", onto = "--onto" }
  for source, source_flag in pairs(source_flags) do
    for placement, placement_flag in pairs(placement_flags) do
      for _, destination in ipairs({ "selection", "trunk", "current", "target" }) do
        local id = ("revision.rebase.%s.%s.%s"):format(source, placement, destination)
        actions[id] = function(context)
          local function run(target, append_output)
            mutate(
              context,
              jj.rebase(source_flag, source_id(context), placement_flag, target),
              { change_id = target },
              append_output
            )
          end
          if destination == "selection" then
            run(change_id(context))
          elseif destination == "trunk" then
            run("trunk()")
          elseif destination == "current" then
            run("@")
          else
            workflow:select_revision_target(context, "Rebase target: ", run)
          end
        end
      end
    end
  end

  actions["revision.restore.changes"] = function(context)
    mutate(context, jj.restore({ "--changes-in", change_id(context) }, file_path(context)))
  end
  actions["revision.restore.descendants"] = function(context)
    mutate(context, jj.restore({ "--changes-in", change_id(context), "--restore-descendants" }, file_path(context)))
  end
  actions["revision.restore.from"] = function(context)
    mutate(context, jj.restore({ "--from", change_id(context) }, file_path(context)))
  end
  actions["revision.restore.into"] = function(context)
    mutate(context, jj.restore({ "--into", change_id(context) }, file_path(context)))
  end
  actions["revision.restore.from_into.destination"] = function(context)
    mutate(
      context,
      jj.restore({ "--from", source_id(context), "--into", change_id(context) }, source_path(context))
    )
  end

  local revert_destinations = {
    ["revision.revert.after.destination"] = "--insert-after",
    ["revision.revert.before.destination"] = "--insert-before",
    ["revision.revert.onto.destination"] = "--onto",
  }
  actions["revision.revert.current"] = function(context)
    mutate(context, jj.revert(change_id(context), "--onto", "@"), true)
  end
  for id, flag in pairs(revert_destinations) do
    actions[id] = function(context)
      mutate(context, jj.revert(source_id(context), flag, change_id(context)), { change_id = change_id(context) })
    end
  end

  actions["workspace.add.path"] = function(context)
    input_command(context, "Workspace path: ", function(path)
      return jj.workspace_add(path)
    end)
  end
  actions["workspace.add.named"] = function(context)
    workflow:input("Workspace path: ", function(path)
      workflow:input("Workspace name: ", function(name)
        mutate(context, jj.workspace_add(path, name))
      end, vim.fs.basename(path))
    end)
  end
  actions["workspace.forget.current"] = function(context)
    mutate(context, jj.workspace_forget())
  end
  actions["workspace.forget.target"] = function(context)
    select_values(context, "Forget workspace: ", function(callback)
      return jj.workspace_names(context.root, callback)
    end, function(name)
      mutate(context, jj.workspace_forget(name))
    end, { allow_custom = false })
  end
  actions["workspace.forget.selection"] = function(context)
    local names = context.commit.workspaces or {}
    if #names == 0 then
      vim.notify("Selection has no workspaces", vim.log.levels.WARN, { title = "Majjit" })
      return
    end
    mutate(context, jj.workspace_forget(names))
  end
  actions["workspace.list"] = function(context)
    select_values(context, "Workspaces: ", function(callback)
      return jj.workspace_names(context.root, callback)
    end, function() end, { allow_custom = false })
  end
  actions["workspace.rename"] = function(context)
    workflow:query(context.root, function(callback)
      return jj.current_workspace_name(context.root, callback)
    end, function(name, err)
      if err then
        vim.notify(err, vim.log.levels.ERROR, { title = "Majjit" })
        return
      end
      workflow:input("Workspace name: ", function(new_name)
        if new_name ~= name then
          mutate(context, jj.workspace_rename(new_name))
        end
      end, name)
    end)
  end
  actions["workspace.update_stale"] = function(context)
    mutate(context, jj.workspace_update_stale())
  end

  actions["git.fetch.default"] = function(context)
    mutate(context, jj.git_fetch(), true)
  end
  actions["git.fetch.all_remotes"] = function(context)
    mutate(context, jj.git_fetch({ "--all-remotes" }), true)
  end
  actions["git.fetch.tracked"] = function(context)
    mutate(context, jj.git_fetch({ "--tracked" }), true)
  end
  actions["git.fetch.branch"] = function(context)
    workflow:select_bookmark(context.root, "Fetch branch: ", function(name, append_output)
      if name then
        mutate(context, jj.git_fetch({ "-b", name }), true, append_output)
      end
    end)
  end
  actions["git.fetch.remote"] = function(context)
    workflow:select_git_remote(context.root, function(remote, append_output)
      if remote then
        mutate(context, jj.git_fetch({ "--remote", remote }), true, append_output)
      end
    end)
  end
  actions["git.push.default"] = function(context)
    mutate(context, jj.git_push(), true)
  end
  actions["git.push.all"] = function(context)
    mutate(context, jj.git_push({ "--all" }), true)
  end
  actions["git.push.revision"] = function(context)
    mutate(context, jj.git_push({ "-r", change_id(context) }), true)
  end
  actions["git.push.tracked"] = function(context)
    mutate(context, jj.git_push({ "--tracked" }), true)
  end
  actions["git.push.deleted"] = function(context)
    mutate(context, jj.git_push({ "--deleted" }), true)
  end
  actions["git.push.change"] = function(context)
    mutate(context, jj.git_push({ "-c", change_id(context) }), true)
  end
  actions["git.push.named"] = function(context)
    input_command(context, "Bookmark name: ", function(name)
      return jj.git_push({ "--named", name .. "=" .. change_id(context) })
    end)
  end
  actions["git.push.bookmark"] = function(context)
    workflow:select_bookmark(context.root, "Push bookmark: ", function(name, append_output)
      if name then
        mutate(context, jj.git_push({ "-b", name }), true, append_output)
      end
    end)
  end

  actions["operation.redo"] = function(context)
    mutate(context, jj.redo())
  end
  actions["operation.undo"] = function(context)
    mutate(context, jj.undo())
  end
  actions["options.ignore_immutable"] = function()
    workflow:toggle_ignore_immutable()
  end
  actions["revision.abandon.selection"] = function(context)
    mutate(context, jj.abandon(change_id(context), {}))
  end
  actions["revision.abandon.retain_bookmarks"] = function(context)
    mutate(context, jj.abandon(change_id(context), { "--retain-bookmarks" }))
  end
  actions["revision.abandon.restore_descendants"] = function(context)
    mutate(context, jj.abandon(change_id(context), { "--restore-descendants" }))
  end
  actions["revision.describe.editor"] = function(context)
    workflow:describe_in_editor(context)
  end
  actions["revision.describe.inline"] = function(context)
    workflow:describe_inline(context)
  end
  actions["revision.edit.selection"] = function(context)
    mutate(context, jj.edit(change_id(context)))
  end
  actions["revision.edit.target"] = function(context)
    workflow:select_revision_target(context, "Edit: ", function(selected, append_output)
      if selected then
        mutate(context, jj.edit(selected), true, append_output)
      end
    end)
  end
  actions["revision.new.after"] = function(context)
    mutate(context, jj.new_revision(change_id(context), {}), true)
  end
  actions["revision.new.insert_after"] = function(context)
    mutate(context, jj.new_revision(change_id(context), { "--insert-after" }), true)
  end
  actions["revision.new.insert_before"] = function(context)
    mutate(context, jj.new_revision(change_id(context), { "--no-edit", "--insert-before" }), true)
  end
  actions["revision.new.trunk"] = function(context)
    mutate(context, jj.new_revision("trunk()", {}), true)
  end
  actions["revision.new.trunk_sync"] = function(context)
    mutate(context, { jj.git_fetch(), jj.new_revision("trunk()", {}) }, true)
  end
  actions["revision.new.target"] = function(context)
    workflow:select_revision_target(context, "New after: ", function(selected, append_output)
      if selected then
        mutate(context, jj.new_revision(selected, {}), true, append_output)
      end
    end)
  end
  actions["revision.new.revsets"] = function(context)
    workflow:input_revset(context)
  end

  actions["view.close"] = close
  actions["view.next_item"] = function()
    workflow:move_item(1, vim.v.count1)
  end
  actions["view.open"] = function()
    workflow:open_file()
  end
  actions["view.previous_item"] = function()
    workflow:move_item(-1, vim.v.count1)
  end
  actions["view.refresh"] = function()
    workflow:refresh()
  end
  actions["view.right_click"] = function()
    workflow:right_click()
  end
  actions["view.select.current"] = function()
    workflow:select_current_working_copy()
  end
  for _, kind in ipairs({ "bookmark", "description", "tag", "target" }) do
    actions["view.select." .. kind] = function()
      workflow:select_visible_commit(kind)
    end
  end
  actions["view.toggle"] = function()
    workflow:toggle_fold()
  end

  return actions
end

return M
