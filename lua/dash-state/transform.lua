-- `transform` section: resolves its children into rows, then hands them to `fn`, which returns the rows
-- to show. `command` turns stdout into rows; `transform` turns rows into rows (add, drop, sort, group).
-- Transforms nest: transform { transform { command } }.

local command = require('dash-state.command')

local M = {}

---@class dash-state.TransformOpts
---@field fn fun(items:snacks.dashboard.Item[], ctx:{dashboard:snacks.dashboard.Class, section:table}):snacks.dashboard.Item[]
---@field limit? integer Applied after `fn`, so `fn` always sees every row; `pinned` rows don't count.
---  show_more and page set this on their children, which is what keeps `fn` from seeing a cut list.

---@param section dash-state.TransformOpts
function M.template(section)
  -- Move children into content, so snacks doesn't render them a second time after this template
  local content = section.content or {}
  section.content = content
  for k, v in ipairs(section) do
    content[k] = v
    section[k] = nil
  end

  return function(dashboard)
    local items = dashboard:resolve(content, {}, section)

    if section.fn then
      local ok, result = pcall(section.fn, items, { dashboard = dashboard, section = section })
      if not ok then
        return { { text = { 'transform failed: ' .. command.first_line(result), hl = 'DiagnosticError' } } }
      end
      items = result or {}
    end

    local shown, count = {}, 0
    for _, item in ipairs(items) do
      if item.pinned or not section.limit or count < section.limit then
        if not item.pinned then
          count = count + 1
        end
        shown[#shown + 1] = command.normalize(item)
      end
    end
    return shown
  end
end

return M
