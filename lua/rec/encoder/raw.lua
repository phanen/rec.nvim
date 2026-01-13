local uv = vim.uv

---@class rec.encoder.Raw : rec.Encoder
---@field file integer?
local M = {}
M.__index = M

---@param width integer
---@param height integer
---@param fps integer
---@param output string
---@return rec.encoder.Raw
M.create = function(width, height, fps, output)
  local self = setmetatable({}, M)
  self.output = output
  self.file = assert(uv.fs_open(output, 'w', 438))
  -- Write header with metadata
  local header = string.format('RAW_RGB %d %d %d\n', width, height, fps)
  uv.fs_write(self.file, header, 0)
  self.width = width
  self.height = height
  self.frame_count = 0
  return self
end

---@param rgb_data string|any
---@return boolean success
function M:write_frame(rgb_data)
  if not self.file then return false end

  local ok
  if type(rgb_data) == 'cdata' then
    local ffi = require('ffi') -- Need FFI for conversion
    local len = self.width * self.height * 3
    local str = ffi.string(rgb_data, len)
    ok = uv.fs_write(self.file, str, -1)
  else
    ok = uv.fs_write(self.file, rgb_data, -1)
  end
  if ok then self.frame_count = self.frame_count + 1 end

  return ok ~= nil
end

function M:close()
  if self.file then
    uv.fs_close(self.file)

    if self.output then
      vim.schedule(
        function()
          vim.notify(
            string.format('Raw video saved: %s (%d frames)', self.output, self.frame_count),
            vim.log.levels.INFO
          )
        end
      )
    end
  end

  self.file = nil
  self.output = nil
  self.frame_count = 0
end

return M
