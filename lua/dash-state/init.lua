if not table.unpack then
  table.unpack = unpack
end

local M = {}

M.state = nil
M.page = 0
-- Consider updating .page to be a table keyed by state name?  Would need a compelling argument

---@alias dash-state.State nil|string|string[]|{nil:boolean}

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

      local apply_limit = nil
      if M.check_state(closed_state) then
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

        if M.state == closed_state then
          if #resolved > apply_limit then
            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                M.state = state
                dashboard:update()
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
                  M.state = closed_state
                  dashboard:update()
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

      local apply_limit = nil
      if collapse and M.state == closed_state then
        apply_limit = limit

        for _,v in ipairs(content) do
          v.limit = apply_limit + 1
        end
      elseif collapse and M.state ~= state then
        return {}
      else
        for _,v in ipairs(content) do
          v.limit = v.original_limit
        end
      end

      return function(dashboard)
        local resolved = dashboard:resolve(content, {}, opts)

        if collapse and M.state == closed_state then
          if #resolved > apply_limit then
            resolved = {table.unpack(resolved, 1, apply_limit)}

            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                M.state = state
                M.page = 0
                dashboard:update()
              end,
            }
          end

          return resolved
        else
          local total = #resolved
          local from = (M.page * per_page) + 1
          local to = math.min(from + per_page, #resolved)

          resolved = {table.unpack(resolved, from, to)}

          local page_total = #resolved
          local total_pages = math.ceil(total / per_page)

          if #resolved > per_page then
            page_total = page_total - 1
            resolved[per_page + 1] = {
              icon = '',
              desc = 'Next Page',
              key = '<PageDown>',
              action = function()
                -- Key doesnt get unbound when updated without the key
                M.page = ((M.page < (total_pages - 1) and M.page + 1) or M.page)
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
                  M.state = closed_state
                  M.page = 0
                  dashboard:update()
                end,
              } or {},
              M.page > 0 and {
                icon = '',
                desc = 'Previous Page',
                key = '<PageUp>',
                action = function()
                  M.page = ((M.page > 0 and M.page - 1) or 0)
                  dashboard:update()
                end
              } or {},
              resolved,
              {
                text = {
                  '' .. from .. ' ... ' .. to .. ' of ' .. total,
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

return M
