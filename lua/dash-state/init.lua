local global_state = {}

global_state.state = nil

global_state.checkState = function(checkState, other)
  return function()
    if type(other) ~= 'function' or other() then
      if type(checkState) == 'table' then
        if global_state.state == nil and checkState['nil'] then
          return true
        end

        for k,v in ipairs(checkState) do
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
    state = function(opts)
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
      local expanded_limit = opts.expanded_limit or 25
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
    end
  }
}

return global_state
