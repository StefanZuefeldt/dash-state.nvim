if not table.unpack then
  table.unpack = unpack
end

local global_state = {}

global_state.state = nil
global_state.page = 0
-- Consider updating .page to be a table keyed by state name?  Would need a compelling argument

global_state.checkState = function(checkState, other)
  return function()
    if type(other) ~= 'function' or other() then
      if type(checkState) == 'table' then
        if global_state.state == nil and checkState['nil'] then
          return true
        end

        for _,v in ipairs(checkState) do
          local result = (v == global_state.state)
          if result then
            return true
          end
        end
        return false
      else
        return global_state.state == checkState
      end
    end
  end
end

global_state.extension = {
  templates = {
    stateful = function(opts)
      if opts.content ~= nil then
        opts.content.enabled = global_state.checkState(opts.state, opts.content.enabled)

        return opts.content
      else
        opts.section = opts.as
        opts.enabled = global_state.checkState(opts.state, opts.enabled)

        return opts
      end
    end,

    show_more = function(opts)
      local closed_state = opts.closed_state
      local state = opts.state
      local limit = opts.limit or 5
      local expanded_limit = opts.expanded_limit or 30
      local content = opts.content

      if type(content) ~= 'table' then
        return {}
      end

      local apply_limit = nil
      if global_state.state == closed_state then
        apply_limit = limit
      elseif global_state.state == state then
        apply_limit = expanded_limit
      else
        return {}
      end

      if #content > 0 then
        for _,v in pairs(content) do
          v.limit = apply_limit + 1
        end
      else
        content.limit = apply_limit + 1
      end

      return function(dashboard)
        local resolved = dashboard:resolve(content, {}, opts)

        if global_state.state == closed_state then
          if #resolved > apply_limit then
            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                global_state.state = state
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
                  global_state.state = closed_state
                  dashboard:update()
                end,
              },
              resolved
            }
          }
        end
      end
    end,


    page = function(opts)
      local closed_state = opts.closed_state
      local state = opts.state
      local limit = opts.limit or 5
      local per_page = opts.per_page or 30
      local content = {}

      for k,v in pairs(opts.content) do
        content[k] = v
      end

      if type(content) ~= 'table' then
        return {}
      end

      local apply_limit = nil
      if global_state.state == closed_state then
        apply_limit = limit

        if #content > 0 then
          for _,v in pairs(content) do
            v.limit = apply_limit + 1
          end
        else
          content.limit = apply_limit + 1
        end
      elseif global_state.state ~= state then
        return {}
      end

      return function(dashboard)
        -- TODO - consider caching?  Maybe a separate type actually
        local resolved = dashboard:resolve(content, {}, opts)

        if global_state.state == closed_state then
          if #resolved > apply_limit then
            resolved = {table.unpack(resolved, 1, apply_limit)}

            resolved[apply_limit + 1] = {
              icon = '',
              desc = 'Show More...',
              key = opts.key,
              autokey = opts.key == nil,
              action = function()
                global_state.state = state
                global_state.page = 0
                dashboard:update()
              end,
            }
          end

          return resolved
        else
          local total = #resolved
          local from = (global_state.page * per_page) + 1
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
                global_state.page = ((global_state.page < (total_pages - 1) and global_state.page + 1) or global_state.page)
                dashboard:update()
              end
            }
          end

          return {
            {
              {
                icon = '',
                desc = 'Return',
                key = opts.key,
                autokey = opts.key == nil,
                padding = 1,
                action = function()
                  global_state.state = closed_state
                  global_state.page = 0
                  dashboard:update()
                end,
              },
              global_state.page > 0 and {
                icon = '',
                desc = 'Previous Page',
                key = '<PageUp>',
                action = function()
                  global_state.page = ((global_state.page > 0 and global_state.page - 1) or 0)
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

return global_state
