local M = {}

M.state = nil
-- Page index per state, so paged sections in different states don't share a counter
M.pages = {}

---@alias dash-state.State nil|string|string[]|{nil:boolean}

---@class dash-state.Layout
---@field width? number|fun(size:{width:number, height:number}):number Never narrower than the dashboard's configured width
---@field row? number

---@class dash-state.Config
---@field reset_on_open? boolean Reset state and pages whenever a new dashboard opens. Default: true.
---  State is shared by all dashboards, so this also resets any dashboard already open elsewhere.
---@field layouts? table<string, dash-state.Layout> Dashboard layout overrides keyed by state name

---@type dash-state.Config
local config = {
  reset_on_open = true,
  layouts = {},
}

---@param opts? dash-state.Config
M.setup = function(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
end

---Checks whether the state object should be considered active
---@param state dash-state.State
M.check_state = function(state)
  if type(state) == 'table' then
    if M.state == nil and state['nil'] then
      return true
    end

    for _,v in ipairs(state) do
      local result = (v == M.state)
      if result then
        return true
      end
    end
    return false
  else
    return M.state == state
  end
end

---The state an action switches to; a table switches to its first named state (or nil)
---@param state dash-state.State
---@return string|nil
local function primary(state)
  if type(state) == 'table' then
    return state[1]
  end
  return state
end

---@param state dash-state.State
M.get_page = function(state)
  return M.pages[tostring(primary(state))] or 0
end

---@param state dash-state.State
---@param page number
M.set_page = function(state, page)
  M.pages[tostring(primary(state))] = page
end

---Switches state, starts all pages over, and redraws
---@param state dash-state.State
---@param dashboard? snacks.dashboard.Class Redraws every open dashboard when omitted
M.set_state = function(state, dashboard)
  M.state = primary(state)
  -- All of them, not just this state's: a section with a table state reads its page under state[1],
  -- which may not be the state being entered
  M.pages = {}
  if dashboard then
    dashboard:update()
  else
    require('snacks').dashboard.update()
  end
end

---Selects a whole section tree by state: `views[state]`, falling back to `views.default`.
---  sections = { require('dash-state').views({ default = {...}, worklist = {...} }) }
---Each update renders a fresh copy, because snacks and these templates modify section tables in place.
---@param views table<string, table>
M.views = function(views)
  return function()
    return vim.deepcopy((M.state and views[M.state]) or views.default or {})
  end
end

---@param dashboard snacks.dashboard.Class
local function on_update(dashboard)
  -- First update of this instance: remember its own layout before any state changes it
  if not dashboard.dash_state_base then
    dashboard.dash_state_base = { width = dashboard.opts.width, row = dashboard.opts.row }
    if config.reset_on_open then
      M.state = nil
      M.pages = {}
    end
  end

  local base = dashboard.dash_state_base
  local layout = (M.state and config.layouts[M.state]) or {}
  local width = layout.width
  if type(width) == 'function' then
    width = width(dashboard._size)
  end
  dashboard.opts.width = width and math.max(math.floor(width), base.width) or base.width
  dashboard.opts.row = layout.row or base.row
end

local function show_more_item(opts, dashboard)
  return {
    icon = '\u{eaf3}',
    desc = 'Show More...',
    key = opts.key,
    autokey = opts.key == nil,
    action = function()
      M.set_state(opts.state, dashboard)
    end,
  }
end

local function return_item(opts, dashboard, padding)
  return {
    icon = '\u{eaf4}',
    desc = 'Return',
    key = opts.key,
    autokey = opts.key == nil,
    padding = padding,
    action = function()
      M.set_state(opts.closed_state, dashboard)
    end,
  }
end

---Shared core of show_more and page. While `closed_state` is active the children are cut to `limit`
---plus a Show More item; while `state` is active `open` builds the expanded view.
---@param opts table The section's options; positional children are moved into opts.content once
---@param spec {collapse:boolean, limit:number, open_limit?:number, open:fun(resolved:table, dashboard:snacks.dashboard.Class):table}
local function expandable(opts, spec)
  -- Move children into content instead - prevent double rendering
  local content = opts.content or {}
  opts.content = content
  for k,v in ipairs(opts) do
    content[k] = v
    content[k].original_limit = v.limit
    opts[k] = nil
  end

  if next(content) == nil then
    return {}
  end

  local collapsed = spec.collapse and M.check_state(opts.closed_state)
  if spec.collapse and not collapsed and not M.check_state(opts.state) then
    return {}
  end

  -- One extra item reveals whether there is more to show
  for _,v in ipairs(content) do
    if collapsed then
      v.limit = spec.limit + 1
    elseif spec.open_limit then
      v.limit = spec.open_limit + 1
    else
      v.limit = v.original_limit
    end
  end

  return function(dashboard)
    local resolved = dashboard:resolve(content, {}, opts)

    if collapsed then
      if #resolved > spec.limit then
        resolved = vim.list_slice(resolved, 1, spec.limit)
        resolved[spec.limit + 1] = show_more_item(opts, dashboard)
      end
      return resolved
    end
    return spec.open(resolved, dashboard)
  end
end

M.extension = {
  templates = {
    ---Creates a section that displays when the state is set
    ---  as: The built-in section or template to use when enabled
    ---  state: The state or set of states to be enabled on.  Default: nil, displays when no state.
    ---@param opts {as?:string, state?:dash-state.State, section?:string, content?:table<string,any>}
    stateful = function(opts)
      -- Move all data into content once
      local content = opts.content or {}
      if not opts.content then
        for k,v in pairs(opts) do
          if k == 'as' then
            content['section'] = v
          elseif k ~= 'section' and k ~= 'state' then
            content[k] = v
            opts[k] = nil
          end
        end
        opts.content = content
      end

      -- Return content or dont
      if M.check_state(opts.state) then
        return content
      end
      return {}
    end,

    ---Turns the contents into a collapsed table of items
    ---When collapsed, state is unset, and limits display to current limit
    ---When expanded, state is set, and limit is increased to expanded_limit
    ---  Additionally, if show_all is set, a Show All option will display
    ---@param opts {state:dash-state.State, closed_state?:dash-state.State, limit?:number, expanded_limit?:number, key?:any, show_all?:fun(), content?:table<string,any>}
    show_more = function(opts)
      local expanded_limit = opts.expanded_limit or 30

      return expandable(opts, {
        collapse = true,
        limit = opts.limit or 5,
        open_limit = expanded_limit,
        open = function(resolved, dashboard)
          if #resolved > expanded_limit then
            resolved = vim.list_slice(resolved, 1, expanded_limit)
            if opts.show_all then
              resolved[expanded_limit + 1] = {
                icon = '\u{f02c5}',
                desc = 'Show All',
                autokey = true,
                action = opts.show_all
              }
            end
          end

          return { { return_item(opts, dashboard), resolved } }
        end,
      })
    end,


    ---Turns the contents into paging table of items
    ---  per_page controls how many items show
    ---  if collapse is set, will collapse to a limited view similar to show_more, controlled by limit
    ---    collapse will also use the state and closed_state parameters like show_more
    ---  <PageDown> and <PageUp> can be used to traverse between pages
    ---  The page index is tracked per state, so each paged section keeps its own place
    ---@param opts {
      ---collapse?:boolean,
      ---state:dash-state.State,
      ---closed_state?:dash-state.State,
      ---limit?:number,
      ---per_page?:number,
      ---key?:any,
      ---content?:table<string,any>,
      ---}
    page = function(opts)
      local collapse = opts.collapse or false
      local state = opts.state
      local per_page = opts.per_page or 30

      return expandable(opts, {
        collapse = collapse,
        limit = opts.limit or 5,
        open = function(resolved, dashboard)
          local total = #resolved
          local total_pages = math.max(math.ceil(total / per_page), 1)

          -- Clamp in case the list shrank since the page was chosen
          local page = math.min(M.get_page(state), total_pages - 1)
          M.set_page(state, page)

          local from = (page * per_page) + 1
          local to = math.min(from + per_page - 1, total)
          local shown = vim.list_slice(resolved, from, to)

          if page < total_pages - 1 then
            shown[#shown + 1] = {
              icon = '\u{f063}',
              desc = 'Next Page',
              key = '<PageDown>',
              action = function()
                M.set_page(state, math.min(M.get_page(state) + 1, total_pages - 1))
                dashboard:update()
              end
            }
          end

          return {
            {
              collapse and return_item(opts, dashboard, 1) or {},
              page > 0 and {
                icon = '\u{f062}',
                desc = 'Previous Page',
                key = '<PageUp>',
                action = function()
                  M.set_page(state, math.max(M.get_page(state) - 1, 0))
                  dashboard:update()
                end
              } or {},
              shown,
              {
                text = {
                  total == 0 and '0 of 0' or (from .. ' ... ' .. to .. ' of ' .. total),
                  hl = 'NonText'
                }
              }
            }
          }
        end,
      })
    end
  }
}

---Snacks extension entry point. Use in place of `extension` to get state layouts and reset-on-open:
---  extensions = { function(d) return require('dash-state').dashboard_extension(d) end }
---@param dashboard snacks.dashboard.Class
M.dashboard_extension = function(dashboard)
  on_update(dashboard)
  return M.extension
end

return M
