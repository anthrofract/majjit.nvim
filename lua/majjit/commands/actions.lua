local jj = require("majjit.jj")

local M = {}

function M.new(workflow, close)
  return {
    ["git.fetch.default"] = function(context)
      workflow:mutate(context, jj.git_fetch(), true)
    end,
    ["git.fetch.all_remotes"] = function(context)
      workflow:mutate(context, jj.git_fetch({ "--all-remotes" }), true)
    end,
    ["git.fetch.tracked"] = function(context)
      workflow:mutate(context, jj.git_fetch({ "--tracked" }), true)
    end,
    ["git.fetch.branch"] = function(context)
      local root = context.root
      workflow:select_bookmark(root, "Fetch branch: ", function(name, append_output)
        workflow:mutate({ root = root }, jj.git_fetch({ "-b", name }), true, append_output)
      end)
    end,
    ["git.fetch.remote"] = function(context)
      local root = context.root
      workflow:select_git_remote(root, function(remote, append_output)
        workflow:mutate({ root = root }, jj.git_fetch({ "--remote", remote }), true, append_output)
      end)
    end,
    ["git.push.default"] = function(context)
      workflow:mutate(context, jj.git_push(), true)
    end,
    ["git.push.all"] = function(context)
      workflow:mutate(context, jj.git_push({ "--all" }), true)
    end,
    ["git.push.revision"] = function(context)
      workflow:mutate(context, jj.git_push({ "-r", context.commit.change_id }), true)
    end,
    ["git.push.tracked"] = function(context)
      workflow:mutate(context, jj.git_push({ "--tracked" }), true)
    end,
    ["git.push.deleted"] = function(context)
      workflow:mutate(context, jj.git_push({ "--deleted" }), true)
    end,
    ["git.push.change"] = function(context)
      workflow:mutate(context, jj.git_push({ "-c", context.commit.change_id }), true)
    end,
    ["git.push.named"] = function(context)
      local root = context.root
      local change_id = context.commit.change_id
      workflow:input("Bookmark name: ", function(name)
        workflow:mutate({ root = root }, jj.git_push({ "--named", name .. "=" .. change_id }), true)
      end)
    end,
    ["git.push.bookmark"] = function(context)
      local root = context.root
      workflow:select_bookmark(root, "Push bookmark: ", function(name, append_output)
        workflow:mutate({ root = root }, jj.git_push({ "-b", name }), true, append_output)
      end)
    end,
    ["operation.redo"] = function(context)
      workflow:mutate(context, jj.redo())
    end,
    ["operation.undo"] = function(context)
      workflow:mutate(context, jj.undo())
    end,
    ["options.ignore_immutable"] = function()
      workflow:toggle_ignore_immutable()
    end,
    ["revision.abandon.selection"] = function(context)
      workflow:mutate(context, jj.abandon(context.commit.change_id, {}))
    end,
    ["revision.abandon.retain_bookmarks"] = function(context)
      workflow:mutate(context, jj.abandon(context.commit.change_id, { "--retain-bookmarks" }))
    end,
    ["revision.abandon.restore_descendants"] = function(context)
      workflow:mutate(context, jj.abandon(context.commit.change_id, { "--restore-descendants" }))
    end,
    ["revision.edit.selection"] = function(context)
      workflow:mutate(context, jj.edit(context.commit.change_id))
    end,
    ["revision.edit.target"] = function(context)
      local root = context.root
      workflow:select_revision_target(context, "Edit: ", function(selected, append_output)
        workflow:mutate({ root = root }, jj.edit(selected), true, append_output)
      end)
    end,
    ["revision.new.after"] = function(context)
      workflow:mutate(context, jj.new_revision(context.commit.change_id, {}), true)
    end,
    ["revision.new.insert_after"] = function(context)
      workflow:mutate(context, jj.new_revision(context.commit.change_id, { "--insert-after" }), true)
    end,
    ["revision.new.insert_before"] = function(context)
      workflow:mutate(context, jj.new_revision(context.commit.change_id, { "--no-edit", "--insert-before" }), true)
    end,
    ["revision.new.trunk"] = function(context)
      workflow:mutate(context, jj.new_revision("trunk()", {}), true)
    end,
    ["revision.new.trunk_sync"] = function(context)
      workflow:mutate(context, { jj.git_fetch(), jj.new_revision("trunk()", {}) }, true)
    end,
    ["revision.new.target"] = function(context)
      local root = context.root
      workflow:select_revision_target(context, "New after: ", function(selected, append_output)
        workflow:mutate({ root = root }, jj.new_revision(selected, {}), true, append_output)
      end)
    end,
    ["revision.new.revsets"] = function(context)
      workflow:input_revset(context)
    end,
    ["view.close"] = close,
    ["view.open"] = function()
      workflow:open_file()
    end,
    ["view.refresh"] = function()
      workflow:refresh()
    end,
    ["view.right_click"] = function()
      workflow:right_click()
    end,
    ["view.select.bookmark"] = function()
      workflow:select_visible_commit("bookmark")
    end,
    ["view.select.description"] = function()
      workflow:select_visible_commit("description")
    end,
    ["view.select.tag"] = function()
      workflow:select_visible_commit("tag")
    end,
    ["view.select.target"] = function()
      workflow:select_visible_commit("target")
    end,
    ["view.toggle"] = function()
      workflow:toggle_fold()
    end,
  }
end

return M
