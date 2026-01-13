local uv = vim.uv
local fn = vim.fn

---@class rec.encoder.FFmpeg : rec.Encoder
---@field handle? uv.uv_process_t
---@field stdin? uv.uv_pipe_t
local M = {}
M.__index = M

---@param width integer
---@param height integer
---@param fps integer
---@param output string
---@return rec.encoder.FFmpeg
M.create = function(width, height, fps, output)
  local self = setmetatable({}, M)
  self.width = width
  self.height = height
  self.stdin = assert(uv.new_pipe(false))
  local cmd = string.format(
    'ffmpeg -y -f rawvideo -pix_fmt rgb24 -s %dx%d -r %d -i pipe:0 -c:v libx264 -preset ultrafast -pix_fmt yuv420p %s 2>/dev/null',
    width,
    height,
    fps,
    fn.shellescape(output)
  )

  self.handle = uv.spawn(
    'sh',
    { args = { '-c', cmd }, stdio = { self.stdin, nil, nil } },
    vim.schedule_wrap(function(code, _)
      if code == 0 then return end
      vim.notify('FFmpeg exited with code: ' .. code, vim.log.levels.ERROR)
    end)
  )
  return self
end

---@param rgb_data string|any
---@return boolean success
function M:write_frame(rgb_data)
  if not self.stdin or self.stdin:is_closing() then return false end
  -- maybe no need to copy it... cdata should be written via ffi.C.write?
  if type(rgb_data) == 'cdata' then
    local ffi = require('ffi') -- Need FFI for conversion
    local len = self.width * self.height * 3
    local str = ffi.string(rgb_data, len)
    self.stdin:write(str)
  else
    self.stdin:write(rgb_data)
  end

  return true
end

function M:close()
  if self.stdin and not self.stdin:is_closing() then self.stdin:close() end
  self.stdin = nil
  self.handle = nil
end

return M
