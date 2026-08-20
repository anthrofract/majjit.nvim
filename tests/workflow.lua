local workflow_module = require("majjit.workflow")

local focused_line
local view = {
  focus_log_line = function(_, line)
    focused_line = line
  end,
  state = { log = { current_line = 7 } },
}
local workflow = workflow_module.new({ view = view })

workflow:select_current_working_copy()
assert(focused_line == 7)

focused_line = nil
view.state.log.current_line = nil
workflow:select_current_working_copy()
assert(focused_line == 1)

focused_line = nil
view.state = nil
workflow:select_current_working_copy()
assert(focused_line == nil)
