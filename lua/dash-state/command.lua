-- `command` section: runs a command in the background, caches its output, and turns it into
-- dashboard items through a `parse` function. Unlike snacks' `terminal` section, the rows are
-- real items, so they take keys/actions, highlights, and work inside show_more/page.

local uv = vim.uv or vim.loop
local truncate = require('snacks.picker.util').truncate

local M = {}

---@class dash-state.CommandItem: snacks.dashboard.Item
---@field texts? {[1]:string, hl?:string, flex?:boolean}[] Row text chunks; a `flex` chunk is truncated to fit

---@class dash-state.CommandOpts
---@field cmd string|string[] A string runs through 'shell'; a list runs directly (preferred)
---@field parse? fun(stdout:string, ctx:{dashboard:snacks.dashboard.Class, section:table}):dash-state.CommandItem[] Default: one row per line
---@field ttl? integer Seconds before the cached output is refreshed. Default: 300
---@field timeout? integer Milliseconds before the command is killed. Default: 30000
---@field cwd? string
---@field limit? integer
---@field icon? string Default icon for rows that don't set one
---@field autokey? boolean Default: true
---@field refresh_key? string Key on every row (and the placeholder) that reruns the command now
---@field loading? string Placeholder while there is no output yet. Default: 'Loading...'
---@field empty? string Placeholder when parse returns no rows. Default: 'Nothing to show'

---@class dash-state.CommandRun
---@field stdout? string Output of the last successful run
---@field time? integer When the last run finished (success or not); nil forces a run
---@field err? string Why the last run failed
---@field running? boolean

local runs = {} ---@type table<string, dash-state.CommandRun>
local cache_dir = vim.fn.stdpath('cache') .. '/dash-state'

local defaults = {
  ttl = 300,
  timeout = 30000,
  autokey = true,
  loading = 'Loading...',
  empty = 'Nothing to show',
}

---@param cmd string|string[]
---@return string[]
local function argv(cmd)
  if type(cmd) == 'table' then
    return cmd
  end
  local args = { vim.o.shell }
  vim.list_extend(args, vim.split(vim.o.shellcmdflag, ' ', { trimempty = true }))
  args[#args + 1] = cmd
  return args
end

---@param opts dash-state.CommandOpts
local function cache_key(opts)
  return vim.fn.sha256(table.concat(argv(opts.cmd), '\0') .. '\0' .. (opts.cwd or ''))
end

local function cache_path(key)
  return cache_dir .. '/' .. key .. '.txt'
end

---Output cached by an earlier session, so the dashboard draws immediately on startup
---@return dash-state.CommandRun
local function load(key)
  local path = cache_path(key)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return {}
  end
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return {}
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return {}
  end
  return { stdout = data, time = stat.mtime.sec }
end

local function save(key, data)
  vim.fn.mkdir(cache_dir, 'p')
  local path = cache_path(key)
  local tmp = path .. '.tmp'
  local fd = uv.fs_open(tmp, 'w', 438)
  if not fd then
    return
  end
  uv.fs_write(fd, data)
  uv.fs_close(fd)
  -- Swap in whole, so a crash mid-write can't leave a truncated cache
  if not uv.fs_rename(tmp, path) then
    uv.fs_unlink(tmp)
  end
end

---@param res vim.SystemCompleted
local function failure(res)
  if res.signal and res.signal ~= 0 then
    return 'timed out'
  end
  local msg = vim.trim(res.stderr or '')
  if msg == '' then
    msg = vim.trim(res.stdout or '')
  end
  return msg ~= '' and msg or ('exit code ' .. res.code)
end

---@param key string
---@param opts dash-state.CommandOpts
local function run(key, opts)
  local r = runs[key]
  r.running = true

  local function done(err, stdout)
    r.running = false
    r.time = os.time()
    r.err = err
    if err then
      -- Stale rows stay up, so say why they didn't refresh; once per failure streak, not every TTL while offline
      if r.stdout and not r.warned then
        r.warned = true
        vim.notify(('dash-state: `%s` failed, showing cached output: %s'):format(table.concat(argv(opts.cmd), ' '), err),
          vim.log.levels.WARN)
      end
    else
      r.warned = nil
      r.stdout = stdout
      save(key, stdout)
    end
    require('snacks').dashboard.update()
  end

  local ok, err = pcall(vim.system, argv(opts.cmd), { text = true, cwd = opts.cwd, timeout = opts.timeout },
    function(res)
      vim.schedule(function()
        if res.code == 0 then
          done(nil, res.stdout or '')
        else
          done(failure(res))
        end
      end)
    end)
  -- e.g. the executable isn't on PATH
  if not ok then
    vim.schedule(function() done(tostring(err)) end)
  end
end

---Reruns a command section's command now. With no key, reruns every command section.
---@param key? string
function M.refresh(key)
  for k, r in pairs(runs) do
    if not key or k == key then
      r.time = nil
    end
  end
  require('snacks').dashboard.update()
end

---Marks a row with `texts` chunks for the `command_row` format. snacks only runs a format for
---non-table fields, so the marker is a boolean and the chunks stay in `texts`. Safe to call twice.
---@param item dash-state.CommandItem
function M.normalize(item)
  if item.texts then
    item.command_row = true
  end
  return item
end

---First line of an error message, for a one-row error display
---@param err any
function M.first_line(err)
  return (tostring(err):gsub('\r?\n.*', ''))
end

---@param kind 'loading'|'error'|'empty' Left on the row as `placeholder`, so a transform can tell it from data
local function placeholder(kind, text, hl)
  return { text = { text, hl = hl }, placeholder = kind }
end

---Default parse: one plain row per non-empty line
local function lines(stdout)
  local items = {}
  for line in vim.gsplit(stdout, '\r?\n') do
    if vim.trim(line) ~= '' then
      items[#items + 1] = { texts = { { line, flex = true } } }
    end
  end
  return items
end

---@param section dash-state.CommandOpts
function M.template(section)
  local opts = vim.tbl_extend('keep', section, defaults)

  return function(dashboard)
    local key = cache_key(opts)
    local r = runs[key]
    if not r then
      r = load(key)
      runs[key] = r
    end
    -- At least a second, so the redraw a finished run triggers can't start the next one
    if not r.running and (not r.time or os.time() - r.time >= math.max(opts.ttl, 1)) then
      run(key, opts)
    end

    local items
    if not r.stdout then
      items = { r.err and placeholder('error', 'Failed: ' .. M.first_line(r.err), 'DiagnosticError')
        or placeholder('loading', opts.loading, 'NonText') }
    else
      local ok, result = pcall(opts.parse or lines, r.stdout, { dashboard = dashboard, section = opts })
      if not ok then
        items = { placeholder('error', 'parse failed: ' .. M.first_line(result), 'DiagnosticError') }
      elseif #result == 0 then
        items = { placeholder('empty', opts.empty, 'NonText') }
      else
        items = opts.limit and vim.list_slice(result, 1, opts.limit) or result
        for _, item in ipairs(items) do
          M.normalize(item)
          if item.icon == nil then
            item.icon = opts.icon
          end
          if item.autokey == nil and (item.action or item.actions) then
            item.autokey = opts.autokey
          end
        end
      end
    end

    -- Every row, placeholders included, so a failed or stuck fetch can be retried from the dashboard
    if opts.refresh_key then
      for _, item in ipairs(items) do
        item.actions = item.actions or {}
        if item.actions[opts.refresh_key] == nil then
          item.actions[opts.refresh_key] = { function() M.refresh(key) end, desc = 'Refresh' }
        end
      end
    end
    return items
  end
end

M.format = {
  priority = 100,
  ---@param item snacks.dashboard.Item
  ---@param ctx {width:number}
  format = function(item, ctx)
    local texts = vim.deepcopy(item.texts)
    local fixed = 0
    for _, t in ipairs(texts) do
      if not t.flex then
        fixed = fixed + vim.fn.strdisplaywidth(t[1])
      end
    end
    -- Flex chunks share what's left, in order
    local room = math.max((ctx.width or math.huge) - fixed, 1)
    local last
    for _, t in ipairs(texts) do
      if t.flex then
        t[1] = truncate(t[1], room)
        room = math.max(room - vim.fn.strdisplaywidth(t[1]), 0)
        t.flex = nil
        last = t
      end
    end
    -- Fill the row, so snacks doesn't center short rows and knock them out of line with the rest
    if last and ctx.width and room > 0 then
      last[1] = last[1] .. string.rep(' ', room)
    end
    return texts
  end,
}

return M
