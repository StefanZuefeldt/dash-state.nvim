if not table.unpack then
  table.unpack = unpack
end

local M = {}

M.state = nil
-- Page index per state, so paged sections in different states don't share a counter
M.pages = {}

---@alias dash-state.State nil|string|string[]|{nil:boolean}

---@class dash-state.Layout
---@field width? number|fun(size:{width:number, height:number}):number Never narrower than the dashboard's configured width
---@field row? number

---@class dash-state.Config
---@field reset_on_open? boolean Reset state and pages whenever a new dashboard opens. Default: true
---@field clear_keys? boolean Unbind the previous render's item keys before redrawing. Default: true
---@field layouts? table<string, dash-state.Layout> Dashboard layout overrides keyed by state name

---@type dash-state.Config
local config = {
  reset_on_open = true,
  clear_keys = true,
  layouts = {},
}

-- Keys snacks binds itself when the dashboard opens; never unbind these
local protected_keys = { q = true, ['<esc>'] = true, ['<cr>'] = true }

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

---Switches state, starts its pages over, and redraws
---@param state dash-state.State
---@param dashboard? snacks.dashboard.Class Redraws every open dashboard when omitted
M.set_state = function(state, dashboard)
  M.state = primary(state)
  M.set_page(M.state, 0)
  if dashboard then
    dashboard:update()
  else
    require('snacks').dashboard.update()
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

  -- Snacks only ever binds item keys, so keys from sections hidden by a state change
  -- would otherwise keep running their old actions
  if config.clear_keys then
    for _,item in ipairs(dashboard.items or {}) do
      if item.key and item.key ~= '' and not protected_keys[item.key:lower()] then
        pcall(vim.keymap.del, 'n', item.key, { buffer = dashboard.buf })
      end
    end
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
      local closed_state = opts.closed_state
      local state = opts.state
      local limit = opts.limit or 5
      local expanded_limit = opts.expanded_limit or 30
      local content = opts.content or {}
      opts.content = content

      for k,v in ipairs(opts) do
        content[k] = v
        opts[k] = nil
      end

      if next(content) == nil then
        return {}
      end

      local collapsed = M.check_state(closed_state)
      local apply_limit = nil
      if collapsed then
        apply_limit = limit
      elseif M.check_state(state) then
        apply_limit = expanded_limit
      else
        return {}
      end

      for _,v in ipairs(content) do
        v.limit = apply_limit + 1
      end

      return function(dashboard)
        local resolved = dashboard:resolve(content, {}, opts)

        if collapsed then
          if #resolved > apply_limit then
            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                M.set_state(state, dashboard)
              end,
            }
          end

          return resolved
        else
          if #resolved > apply_limit then
            if opts.show_all then
              resolved[apply_limit + 1] = {
                icon = '󰋅',
                desc = 'Show All',
                autokey = true,
                action = opts.show_all
              }
            else
              resolved[apply_limit + 1] = nil
            end
          end

          return {
            {
              {
                icon = '',
                desc = 'Return',
                key = opts.key,
                autokey = opts.key == nil,
                action = function()
                  M.set_state(closed_state, dashboard)
                end,
              },
              resolved
            }
          }
        end
      end
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
      local closed_state = opts.closed_state
      local state = opts.state
      local limit = opts.limit or 5
      local per_page = opts.per_page or 30
      local content = opts.content or {}
      opts.content = content

      -- Move children into content instead - prevent double rendering
      for k,v in ipairs(opts) do
        content[k] = v
        content[k].original_limit = v.limit
        opts[k] = nil
      end

      if next(content) == nil then
        return {}
      end

      local collapsed = collapse and M.check_state(closed_state)
      local apply_limit = nil
      if collapsed then
        apply_limit = limit

        for _,v in ipairs(content) do
          v.limit = apply_limit + 1
        end
      elseif collapse and not M.check_state(state) then
        return {}
      else
        for _,v in ipairs(content) do
          v.limit = v.original_limit
        end
      end

      return function(dashboard)
        local resolved = dashboard:resolve(content, {}, opts)

        if collapsed then
          if #resolved > apply_limit then
            resolved = {table.unpack(resolved, 1, apply_limit)}

            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                M.set_state(state, dashboard)
              end,
            }
          end

          return resolved
        else
          local total = #resolved
          local total_pages = math.max(math.ceil(total / per_page), 1)

          -- Clamp in case the list shrank since the page was chosen
          local page = math.min(M.get_page(state), total_pages - 1)
          M.set_page(state, page)

          local from = (page * per_page) + 1
          local to = math.min(from + per_page - 1, total)
          local shown = {table.unpack(resolved, from, to)}

          if page < total_pages - 1 then
            shown[#shown + 1] = {
              icon = '',
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
              collapse and {
                icon = '',
                desc = 'Return',
                key = opts.key,
                autokey = opts.key == nil,
                padding = 1,
                action = function()
                  M.set_state(closed_state, dashboard)
                end,
              } or {},
              page > 0 and {
                icon = '',
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
        end
      end
    end
  }
}

---Snacks extension entry point. Use in place of `extension` to get state layouts,
---reset-on-open, and stale key clearing:
---  extensions = { function(d) return require('dash-state').dashboard_extension(d) end }
---@param dashboard snacks.dashboard.Class
M.dashboard_extension = function(dashboard)
  on_update(dashboard)
  return M.extension
end

return M
