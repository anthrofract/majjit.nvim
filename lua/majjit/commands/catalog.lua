local function action(id, key, label, requires)
  return {
    kind = "action",
    id = id,
    keys = { key },
    label = label,
    requires = requires,
  }
end

local function menu(id, key, label, children, requires, capture)
  return {
    kind = "menu",
    id = id,
    keys = { key },
    label = label,
    children = children,
    requires = requires,
    capture = capture,
  }
end

local REBASE_SOURCES = {
  { id = "branch", key = "b", label = "Selected branch" },
  { id = "source", key = "s", label = "Selected source" },
  { id = "revision", key = "r", label = "Selected revision" },
}
local REBASE_PLACEMENTS = {
  { id = "after", key = "a", label = "Insert after" },
  { id = "before", key = "b", label = "Insert before" },
  { id = "onto", key = "o", label = "Onto" },
}
local REBASE_DESTINATIONS = {
  { id = "selection", key = "<CR>", label = "Select destination", requires = { "commit" } },
  { id = "trunk", key = "m", label = "Trunk", requires = { "repository" } },
  { id = "current", key = "c", label = "@", requires = { "repository" } },
  { id = "target", key = "/", label = "Target", requires = { "repository" } },
}

local function rebase_menu()
  local children = {
    action("revision.rebase.branch.trunk", "m", "Selected branch onto trunk", { "commit" }),
    action("revision.rebase.branch.trunk_sync", "M", "Selected branch onto trunk (sync)", { "commit" }),
    action("revision.rebase.custom", "c", "Custom", { "repository" }),
  }

  for _, source in ipairs(REBASE_SOURCES) do
    local placements = {}
    for _, placement in ipairs(REBASE_PLACEMENTS) do
      local destinations = {}
      for _, destination in ipairs(REBASE_DESTINATIONS) do
        destinations[#destinations + 1] = action(
          ("revision.rebase.%s.%s.%s"):format(source.id, placement.id, destination.id),
          destination.key,
          destination.label,
          destination.requires
        )
      end
      placements[#placements + 1] = menu(
        ("revision.rebase.%s.%s"):format(source.id, placement.id),
        placement.key,
        placement.label,
        destinations
      )
    end
    children[#children + 1] = menu(
      ("revision.rebase.%s"):format(source.id),
      source.key,
      source.label,
      placements,
      { "commit" },
      "source"
    )
  end

  return menu("revision.rebase", "r", "Rebase", children)
end

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
  commands = {
    {
      kind = "menu",
      id = "revision.abandon",
      keys = { "a" },
      group = "Commands",
      label = "Abandon",
      children = {
        {
          kind = "action",
          id = "revision.abandon.selection",
          keys = { "a" },
          label = "Selection",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.abandon.retain_bookmarks",
          keys = { "b" },
          label = "Selection (retain bookmarks)",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.abandon.restore_descendants",
          keys = { "d" },
          label = "Selection (restore descendants)",
          requires = { "commit" },
        },
      },
    },
    menu("revision.absorb", "A", "Absorb", {
      action("revision.absorb.selection", "a", "From selection", { "commit" }),
      menu("revision.absorb.into", "i", "From selection into destination", {
        action("revision.absorb.into.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    menu("bookmark", "b", "Bookmark", {
      action("bookmark.advance", "a", "Advance to selection", { "commit" }),
      action("bookmark.create", "c", "Create at selection", { "commit" }),
      menu("bookmark.list", "L", "List", {
        action("bookmark.list.all", "a", "All", { "repository" }),
        action("bookmark.list.local", "L", "Local only", { "repository" }),
        action("bookmark.list.tracked", "t", "Tracked remote", { "repository" }),
        action("bookmark.list.untracked", "u", "Untracked remote", { "repository" }),
        action("bookmark.list.conflicted", "c", "Conflicted", { "repository" }),
      }),
      menu("bookmark.move", "m", "Move", {
        menu("bookmark.move.selection", "m", "Selected bookmark to destination", {
          action("bookmark.move.selection.destination", "<CR>", "Select destination", { "commit" }),
        }, { "commit" }, "source"),
        menu("bookmark.move.allow_backwards", "M", "Selected bookmark to destination (allow backwards)", {
          action("bookmark.move.allow_backwards.destination", "<CR>", "Select destination", { "commit" }),
        }, { "commit" }, "source"),
      }),
      action("bookmark.rename", "r", "Rename", { "repository" }),
      action("bookmark.track", "t", "Track", { "repository" }),
      action("bookmark.untrack", "u", "Untrack", { "repository" }),
      action("bookmark.delete", "d", "Delete", { "repository" }),
      action("bookmark.forget", "f", "Forget", { "repository" }),
      action("bookmark.forget_remotes", "F", "Forget (including remotes)", { "repository" }),
      action("bookmark.set", "s", "Set to selection", { "commit" }),
      action("bookmark.set_allow_backwards", "S", "Set to selection (allow backwards)", { "commit" }),
    }),
    action("commands.custom", "C", "Custom", { "repository" }),
    menu("revision.commit", "c", "Commit", {
      action("revision.commit.selection", "c", "Commit", { "repository" }),
      action("revision.commit.edit", "C", "Commit (edit description)", { "repository" }),
    }),
    {
      kind = "menu",
      id = "revision.describe",
      keys = { "d" },
      group = "Commands",
      label = "Describe",
      children = {
        {
          kind = "action",
          id = "revision.describe.inline",
          keys = { "d" },
          label = "Selection",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.describe.editor",
          keys = { "D" },
          label = "Selection in editor",
          requires = { "commit" },
        },
      },
    },
    menu("revision.duplicate", "D", "Duplicate", {
      action("revision.duplicate.selection", "d", "Selection", { "commit" }),
      menu("revision.duplicate.onto", "o", "Selection onto destination", {
        action("revision.duplicate.onto.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      menu("revision.duplicate.after", "a", "Selection insert after destination", {
        action("revision.duplicate.after.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      menu("revision.duplicate.before", "b", "Selection insert before destination", {
        action("revision.duplicate.before.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    {
      kind = "menu",
      id = "revision.edit",
      keys = { "e" },
      group = "Commands",
      label = "Edit",
      children = {
        {
          kind = "action",
          id = "revision.edit.selection",
          keys = { "e" },
          label = "Selection",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.edit.target",
          keys = { "/" },
          label = "Target",
          requires = { "repository" },
        },
      },
    },
    menu("file", "f", "File", {
      action("file.track", "t", "Track (enter filepath)", { "repository" }),
      action("file.untrack", "u", "Untrack selection (must be ignored)", { "file" }),
    }),
    {
      kind = "menu",
      id = "git",
      keys = { "g" },
      group = "Commands",
      label = "Git",
      children = {
        {
          kind = "menu",
          id = "git.fetch",
          keys = { "f" },
          group = "Git",
          label = "Fetch",
          children = {
            {
              kind = "action",
              id = "git.fetch.default",
              keys = { "f" },
              group = "Git fetch",
              label = "Default",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.fetch.all_remotes",
              keys = { "a" },
              group = "Git fetch",
              label = "All remotes",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.fetch.tracked",
              keys = { "t" },
              group = "Git fetch",
              label = "Tracked bookmarks and tags",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.fetch.branch",
              keys = { "b" },
              group = "Git fetch",
              label = "Branch by name",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.fetch.remote",
              keys = { "r" },
              group = "Git fetch",
              label = "Remote by name",
              requires = { "repository" },
            },
          },
        },
        {
          kind = "menu",
          id = "git.push",
          keys = { "p" },
          group = "Git",
          label = "Push",
          children = {
            {
              kind = "action",
              id = "git.push.default",
              keys = { "p" },
              group = "Git push",
              label = "Default",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.push.all",
              keys = { "a" },
              group = "Git push",
              label = "All bookmarks and tags",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.push.revision",
              keys = { "r" },
              group = "Git push",
              label = "Bookmarks and tags at selection",
              requires = { "commit" },
            },
            {
              kind = "action",
              id = "git.push.tracked",
              keys = { "t" },
              group = "Git push",
              label = "Tracked bookmarks and tags",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.push.deleted",
              keys = { "d" },
              group = "Git push",
              label = "Deleted bookmarks and tags",
              requires = { "repository" },
            },
            {
              kind = "action",
              id = "git.push.change",
              keys = { "c" },
              group = "Git push",
              label = "New bookmark for selection",
              requires = { "commit" },
            },
            {
              kind = "action",
              id = "git.push.named",
              keys = { "n" },
              group = "Git push",
              label = "New named bookmark for selection",
              requires = { "commit" },
            },
            {
              kind = "action",
              id = "git.push.bookmark",
              keys = { "b" },
              group = "Git push",
              label = "Bookmark by name",
              requires = { "repository" },
            },
          },
        },
      },
    },
    menu("revision.metaedit", "m", "Metaedit", {
      action("revision.metaedit.update_change_id", "c", "Update change-id", { "commit" }),
      action("revision.metaedit.update_author_timestamp", "t", "Update author timestamp to now", { "commit" }),
      action("revision.metaedit.update_author", "a", "Update author to configured user", { "commit" }),
      action("revision.metaedit.set_author", "A", "Set author", { "commit" }),
      action("revision.metaedit.set_author_timestamp", "T", "Set author timestamp", { "commit" }),
      action("revision.metaedit.force_rewrite", "r", "Force rewrite", { "commit" }),
    }),
    menu("log.revset", "L", "Log revset", {
      action("log.revset.default", "d", "Default", { "repository" }),
      action("log.revset.jj_default", "D", "Jj default", { "repository" }),
      action("log.revset.custom", "L", "Custom", { "repository" }),
      action("log.revset.all", "a", "All commits", { "repository" }),
      action("log.revset.mutable", "m", "Mutable", { "repository" }),
      action("log.revset.stack", "s", "Current stack", { "repository" }),
      action("log.revset.conflicts", "c", "Conflicts", { "repository" }),
      action("log.revset.working_copy_ancestry", "w", "@ ancestry", { "repository" }),
      action("log.revset.mine", "i", "Mine", { "repository" }),
      action("log.revset.bookmarks", "b", "Bookmarks and tags", { "repository" }),
      action("log.revset.recent", "r", "Recent", { "repository" }),
    }),
    {
      kind = "menu",
      id = "revision.new",
      keys = { "n" },
      group = "Commands",
      label = "New",
      children = {
        {
          kind = "action",
          id = "revision.new.after",
          keys = { "n" },
          label = "After selection",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.new.insert_after",
          keys = { "a" },
          label = "After selection (rebase children)",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.new.insert_before",
          keys = { "b" },
          label = "Before selection (rebase children)",
          requires = { "commit" },
        },
        {
          kind = "action",
          id = "revision.new.trunk",
          keys = { "m" },
          label = "After trunk",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "revision.new.trunk_sync",
          keys = { "M" },
          label = "After trunk (sync)",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "revision.new.target",
          keys = { "/" },
          label = "After target",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "revision.new.revsets",
          keys = { "r" },
          label = "After revsets",
          requires = { "repository" },
        },
      },
    },
    menu("navigation.next", "N", "Next", {
      action("navigation.next.default", "n", "Next", { "commit" }),
      action("navigation.next.nth", "N", "Nth next", { "commit" }),
      action("navigation.next.edit", "e", "Next (edit)", { "commit" }),
      action("navigation.next.nth_edit", "E", "Nth next (edit)", { "commit" }),
      action("navigation.next.no_edit", "x", "Next (no-edit)", { "commit" }),
      action("navigation.next.nth_no_edit", "X", "Nth next (no-edit)", { "commit" }),
      action("navigation.next.conflict", "c", "Next conflict", { "commit" }),
    }),
    menu("revision.parallelize", "p", "Parallelize", {
      action("revision.parallelize.selection", "p", "Selection with parent", { "commit" }),
      menu("revision.parallelize.range", "P", "From selection to destination", {
        action("revision.parallelize.range.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      action("revision.parallelize.revset", "r", "Revset", { "repository" }),
    }),
    menu("navigation.previous", "P", "Previous", {
      action("navigation.previous.default", "p", "Previous", { "commit" }),
      action("navigation.previous.nth", "P", "Nth previous", { "commit" }),
      action("navigation.previous.edit", "e", "Previous (edit)", { "commit" }),
      action("navigation.previous.nth_edit", "E", "Nth previous (edit)", { "commit" }),
      action("navigation.previous.no_edit", "x", "Previous (no-edit)", { "commit" }),
      action("navigation.previous.nth_no_edit", "X", "Nth previous (no-edit)", { "commit" }),
      action("navigation.previous.conflict", "c", "Previous conflict", { "commit" }),
    }),
    menu("revision.squash", "s", "Squash", {
      action("revision.squash.parent", "s", "Selection into parent", { "commit" }),
      action("revision.squash.parent_edit", "S", "Selection into parent (edit description)", { "commit" }),
      menu("revision.squash.into", "i", "Selection into destination", {
        action("revision.squash.into.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      menu("revision.squash.into_edit", "I", "Selection into destination (edit description)", {
        action("revision.squash.into_edit.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    action("repository.status", "t", "Status", { "repository" }),
    menu("revision.sign", "G", "Sign", {
      action("revision.sign.selection", "s", "Selection", { "commit" }),
      menu("revision.sign.range", "G", "From selection to destination", {
        action("revision.sign.range.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      action("revision.unsign.selection", "u", "Unsign selection", { "commit" }),
      menu("revision.unsign.range", "U", "Unsign from selection to destination", {
        action("revision.unsign.range.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    menu("revision.simplify_parents", "y", "Simplify parents", {
      action("revision.simplify_parents.selection", "y", "Selection", { "commit" }),
      action("revision.simplify_parents.descendants", "Y", "Selection with descendants", { "commit" }),
    }),
    rebase_menu(),
    menu("revision.restore", "R", "Restore", {
      action("revision.restore.changes", "r", "Changes in selection", { "commit" }),
      action("revision.restore.descendants", "d", "Changes in selection (restore descendants)", { "commit" }),
      action("revision.restore.from", "f", "From selection into @", { "commit" }),
      action("revision.restore.into", "i", "From @ into selection", { "commit" }),
      menu("revision.restore.from_into", "R", "From selection into destination", {
        action("revision.restore.from_into.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    {
      kind = "menu",
      id = "view.select",
      keys = { "/" },
      group = "Commands",
      label = "Select",
      children = {
        {
          kind = "action",
          id = "view.select.target",
          keys = { "/" },
          label = "Target",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "view.select.bookmark",
          keys = { "b" },
          label = "Bookmark",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "view.select.description",
          keys = { "d" },
          label = "Description",
          requires = { "repository" },
        },
        {
          kind = "action",
          id = "view.select.tag",
          keys = { "t" },
          label = "Tag",
          requires = { "repository" },
        },
      },
    },
    menu("revision.revert", "V", "Revert", {
      action("revision.revert.current", "v", "Selection onto @", { "commit" }),
      menu("revision.revert.onto", "o", "Selection onto destination", {
        action("revision.revert.onto.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      menu("revision.revert.after", "a", "Selection after destination", {
        action("revision.revert.after.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
      menu("revision.revert.before", "b", "Selection before destination", {
        action("revision.revert.before.destination", "<CR>", "Select destination", { "commit" }),
      }, { "commit" }, "source"),
    }),
    menu("workspace", "w", "Workspace", {
      menu("workspace.add", "a", "Add", {
        action("workspace.add.path", "a", "By path (name from path)", { "repository" }),
        action("workspace.add.named", "n", "By name and path", { "repository" }),
      }),
      menu("workspace.forget", "f", "Forget", {
        action("workspace.forget.current", "c", "Current", { "repository" }),
        action("workspace.forget.target", "/", "Target", { "repository" }),
        action("workspace.forget.selection", "f", "All at selected change", { "commit" }),
      }),
      action("workspace.list", "L", "List", { "repository" }),
      action("workspace.rename", "r", "Rename current", { "repository" }),
      action("workspace.update_stale", "u", "Update stale", { "repository" }),
    }),
    {
      kind = "menu",
      id = "operation.undo_redo",
      keys = { "u" },
      group = "Commands",
      label = "Undo/Redo",
      children = {
        {
          kind = "action",
          id = "operation.undo",
          keys = { "u" },
          label = "Undo last operation",
        },
        {
          kind = "action",
          id = "operation.redo",
          keys = { "r" },
          label = "Redo last operation",
        },
      },
    },
    {
      kind = "action",
      id = "options.ignore_immutable",
      keys = { "I" },
      group = "General",
      label = "Toggle --ignore-immutable",
      available_during_session = true,
      preserve_session = true,
    },
    {
      kind = "action",
      id = "view.close",
      keys = { "q" },
      group = "General",
      label = "Close",
      available_during_session = true,
    },
    {
      kind = "action",
      id = "view.open",
      keys = { "<CR>", "o" },
      group = "General",
      label = "Open",
      requires = { "file" },
    },
    {
      kind = "action",
      id = "view.refresh",
      keys = { "<C-r>", "<BS>" },
      group = "General",
      label = "Refresh",
      available_during_session = true,
    },
    {
      kind = "action",
      id = "view.toggle",
      keys = { "<Tab>", "za" },
      group = "General",
      label = "Toggle fold",
      requires = { "foldable" },
      available_during_session = true,
      preserve_session = true,
    },
    {
      kind = "action",
      id = "view.right_click",
      keys = { "<RightMouse>", "<2-RightMouse>", "<3-RightMouse>", "<4-RightMouse>" },
      hidden = true,
      label = "Select and toggle fold",
      available_during_session = true,
      preserve_session = true,
    },
  },
}
