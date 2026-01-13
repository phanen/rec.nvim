local M = {}

--- Worker entry point, runs in a new thread
---@param fd integer
---@param opts rec.Options
---@param interval integer
local x264_entry = function(fd, opts, interval)
  local x264 = require('rec.encoder.x264')
  local client = require('rec.rpc.client').connect(opts.address)
  -- setmetatable(vim.api, { __index = rpc_client.api })
  vim.api = client.api
  vim.fn = client.fn
  local uv = vim.uv
  local screen = require('rec.screen')
  local font = require('rec.font')

  local round = function(i) return i + (i % 2) end
  local cols, lines = screen.size()
  local width, height = round(cols * opts.char_width), round(lines * opts.char_height)

  if opts.use_font then font.init(opts.font_path, opts.char_width, opts.char_height) end
  local render = opts.use_font and require('rec.render').font or require('rec.render').pixel

  local encoder = x264.create(width, height, opts.fps, opts.output)
  if not encoder then return end

  local loop = function()
    local grid = screen.grid()
    if not grid or not grid.width or not grid.height or not grid.cells then return end
    local rgb_data = render(grid, opts.char_width, opts.char_height)
    if not rgb_data then return end
    encoder:write_frame(rgb_data)
  end

  local timer = assert(uv.new_timer())

  local pipe = assert(uv.new_pipe(false))
  assert(pipe:open(fd))

  local release = function()
    if not timer:is_closing() then timer:close() end
    if not pipe:is_closing() then pipe:close() end
    if encoder then
      encoder:close()
      encoder = nil
    end
    if client then
      client:close() ---@diagnostic disable-next-line: assign-type-mismatch
      client = nil
    end
    font.cleanup()
  end

  -- Listen for the pipe to be closed, which is the signal to stop.
  pipe:read_start(function(err, chunk)
    if err or not chunk or pipe:is_closing() then release() end
  end)

  local pending_action
  -- timer:start(0, interval, function()
  timer:start(0, interval, function()
    pending_action = loop
    uv.stop()
  end)

  if pipe:is_closing() then release() end

  -- https://github.com/neovim/neovim/issues/37376#issuecomment-3741886611
  while uv.run('default') do
    if pending_action then
      pending_action()
      pending_action = nil
    else
      break
    end
  end
  release()
end

---@class rec.Encoder
---@field width integer
---@field height integer
---@field fps integer
---@field output string
---@field frame_count integer
---@field create fun(width: integer, height: integer, fps: integer, output: string): boolean
---@field write_frame fun(self: rec.Encoder, rgb_data: string): boolean
---@field close fun(self: rec.Encoder)

---@param opts rec.Options
---@return fun()? dispose
---@return string? error_message
M.dispatch = function(opts)
  local interval = math.floor(1000 / opts.fps)

  local round = function(i) return i + (i % 2) end
  local cols, lines = require('rec.screen').size()
  local width, height = round(cols * opts.char_width), round(lines * opts.char_height)

  if opts.kind == 'x264' then
    local thread, err = require('rec.thread').spawn(x264_entry, opts, interval)
    if not thread or err then return nil, err end
    return function() thread:close() end, nil
  end

  local Encoder = vim.F.npcall(require, 'rec.encoder.' .. opts.kind)
  if not Encoder then return nil, 'Unsupported encoder kind: ' .. tostring(opts.kind) end
  local encoder = Encoder.create(width, height, opts.fps, opts.output)
  local font = require('rec.font')
  if opts.use_font then font.init(opts.font_path, opts.char_width, opts.char_height) end
  local render = opts.use_font and require('rec.render').font or require('rec.render').pixel

  local timer = assert(vim.uv.new_timer())
  timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if not encoder or timer:is_closing() then return end
      local rgb_data = render(require('rec.screen').grid(), opts.char_width, opts.char_height)
      if not rgb_data then return end
      encoder:write_frame(rgb_data)
    end)
  )
  return function()
    if not timer:is_closing() then timer:close() end
    encoder:close()
    font.cleanup()
  end,
    nil
end

return M
