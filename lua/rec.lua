local M = {}

local lv = vim.log.levels

---@class rec.State
---@field dispose? fun()
---@field output? string
local state = {}

---@class (exact) rec.Options
---@field fps integer Frames per second
---@field output string Output file path
---@field char_width integer Character width in pixels
---@field char_height integer Character height in pixels
---@field use_font boolean Whether to use font rendering
---@field font_path string Path to font file
---@field address string Neovim server for RPC connection
---@field kind "ffmpeg"|"x264"|"raw" Encoder type

---@type rec.Options|{}
local default_config = {
  fps = 30,
  output = '/tmp/record.mp4',
  char_width = 10,
  char_height = 20,
  use_font = true,
  font_path = '/usr/share/fonts/TTF/CaskaydiaCoveNerdFontMono-Bold.ttf',
  -- kind = 'ffmpeg',
  kind = 'x264',
  address = vim.v.servername,
}

---@param opts? rec.Options|{}
M.start = function(opts)
  if state.dispose then
    vim.notify('Already recording', lv.WARN)
    return
  end
  ---@type rec.Options
  opts = vim.tbl_deep_extend('force', default_config, opts or {})

  local dispose, err = require('rec.task').dispatch(opts)
  if err then
    vim.notify('Failed to start recorder: ' .. err, lv.ERROR)
    return
  end
  state.dispose = dispose
  state.output = opts.output
  vim.notify('Recording started: ' .. state.output, lv.INFO)
end

---@return string? output The output file path or nil if not recording
M.stop = function()
  if not state.dispose then
    vim.notify('Not recording', lv.WARN)
    return
  end
  state.dispose()
  state.dispose = nil
  vim.notify('Recording stopped: ' .. state.output, lv.INFO)
  return state.output
end

---@param opts? rec.Options
---@return string? output The output file path if stopped, nil otherwise
M.toggle = function(opts)
  if state.dispose then
    return M.stop()
  else
    return M.start(opts)
  end
end

return M
