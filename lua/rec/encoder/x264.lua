local ffi = require('ffi')

local define_cdefs = function()
  -- Ensure dependencies are defined
  ffi.cdef [[
    typedef unsigned char uint8_t;
    typedef unsigned int uint32_t;
    typedef int32_t int32_t;
    typedef long long int64_t;
    int write (int __fd, const void *__buf, size_t __n);
  ]]

  ffi.cdef([[
  typedef struct x264_t x264_t;
  typedef struct x264_param_t x264_param_t;

  typedef struct x264_image_t {
    int i_csp; int i_plane; int i_stride[4]; uint8_t *plane[4];
  } x264_image_t;

  typedef struct x264_image_properties_t { uint8_t dummy[80]; } x264_image_properties_t;
  typedef struct x264_hrd_t { uint8_t dummy[32]; } x264_hrd_t;
  typedef struct x264_sei_t { uint8_t dummy[24]; } x264_sei_t;

  typedef struct x264_picture_t {
    int i_type; int i_qpplus1; int i_pic_struct; int b_keyframe; int64_t i_pts; int64_t i_dts;
    x264_param_t *param; x264_image_t img; x264_image_properties_t prop; x264_hrd_t hrd_timing;
    x264_sei_t extra_sei; void *opaque;
  } x264_picture_t;

  typedef struct x264_nal_t {
    int i_ref_idc; int i_type; int b_long_startcode; int i_first_mb; int i_last_mb;
    int i_payload; uint8_t *p_payload; int i_padding;
  } x264_nal_t;

  int x264_param_default_preset(x264_param_t *param, const char *preset, const char *tune);
  int x264_param_apply_profile(x264_param_t *param, const char *profile);
  int x264_param_parse(x264_param_t *param, const char *name, const char *value);
  x264_t *x264_encoder_open_165(x264_param_t *param);
  void x264_encoder_close(x264_t *encoder);
  int x264_encoder_encode(x264_t *encoder, x264_nal_t **pp_nal, int *pi_nal, x264_picture_t *pic_in, x264_picture_t *pic_out);
  int x264_encoder_headers(x264_t *encoder, x264_nal_t **pp_nal, int *pi_nal);
  int x264_encoder_delayed_frames(x264_t *encoder);
  void x264_picture_init(x264_picture_t *pic);
  int x264_picture_alloc(x264_picture_t *pic, int i_csp, int i_width, int i_height);
  void x264_picture_clean(x264_picture_t *pic);
]])
end

local lib = nil
---@return any
local load = function()
  if lib then return lib end

  define_cdefs()

  for _, name in ipairs({ 'x264', 'libx264.so.165', 'libx264.so' }) do
    local ok, l = pcall(ffi.load, name)
    if ok then
      lib = l
      return lib
    end
  end
  return
end

-- Allocates a larger buffer than struct to prevent overflow if struct definitions mismatch
local new_safe = function(type_name, size)
  size = size or 4096
  local buf = ffi.new('uint8_t[?]', size)
  ffi.fill(buf, size)
  return ffi.cast(type_name .. '*', buf), buf -- Return ptr and buf (to keep ref)
end

---@class rec.encoder.X264: rec.Encoder
---@field lib any
---@field pts integer
---@field handle integer
---@field pic_in any
---@field pic_in_buf any
---@field param any
---@field param_buf any
---@field file integer
local M = {}
M.__index = M

---@param width integer
---@param height integer
---@param fps integer
---@param output string
M.create = function(width, height, fps, output)
  local x264 = load()
  if not x264 then return end

  local self = setmetatable({
    lib = x264,
    width = width,
    height = height,
    fps = fps,
    output = output,
    pts = 0,
    handle = nil,
    pic_in = nil, ---@type any
    pic_in_buf = nil,
    param = nil,
    param_buf = nil,
  }, M)
  self.file = assert(vim.uv.fs_open(self.output, 'w', 438))

  self.param, self.param_buf = new_safe('x264_param_t')

  if x264.x264_param_default_preset(self.param, 'veryfast', 'zerolatency') < 0 then return end

  x264.x264_param_parse(self.param, 'width', tostring(width))
  x264.x264_param_parse(self.param, 'height', tostring(height))
  x264.x264_param_parse(self.param, 'fps', tostring(fps) .. '/1')
  x264.x264_param_parse(self.param, 'vfr', '0')
  x264.x264_param_parse(self.param, 'repeat_headers', '1')

  local p_raw = ffi.cast('uint8_t*', self.param)
  ffi.cast('int*', p_raw + 28)[0] = width
  ffi.cast('int*', p_raw + 32)[0] = height
  ffi.cast('int*', p_raw + 36)[0] = 2 -- I420

  x264.x264_param_apply_profile(self.param, 'high')

  self.handle = x264.x264_encoder_open_165(self.param)
  if not self.handle then return end

  self.pic_in, self.pic_in_buf = new_safe('x264_picture_t')
  x264.x264_picture_init(self.pic_in)
  x264.x264_picture_alloc(self.pic_in, 2, width, height)

  self:write_headers()
  return self
end

function M:write_headers()
  local pp_nal = ffi.new('x264_nal_t*[1]')
  local pi_nal = ffi.new('int[1]')
  local ret = self.lib.x264_encoder_headers(self.handle, pp_nal, pi_nal)
  if ret > 0 then ffi.C.write(self.file, pp_nal[0].p_payload, ret) end
end

---@param rgb_data any
function M:write_frame(rgb_data)
  local pp_nal = ffi.new('x264_nal_t*[1]')
  local pi_nal = ffi.new('int[1]')
  local pic_out, _ = new_safe('x264_picture_t')

  local rshift = bit.rshift
  local arshift = bit.arshift

  local rgb = ffi.cast('uint8_t*', rgb_data)
  local pic = self.pic_in
  local y_plane, u_plane, v_plane = pic.img.plane[0], pic.img.plane[1], pic.img.plane[2] ---@type integer,integer,integer
  local y_stride, u_stride = pic.img.i_stride[0], pic.img.i_stride[1] ---@type integer,integer
  for y = 0, self.height - 1 do
    local row_rgb = rgb + y * self.width * 3 ---@type any
    local row_y = y_plane + y * y_stride ---@type any
    for x = 0, self.width - 1 do
      local r, g, b = row_rgb[0], row_rgb[1], row_rgb[2] ---@type integer,integer,integer
      row_rgb = row_rgb + 3
      local yval = rshift(19595 * r + 38469 * g + 7471 * b, 16)
      row_y[x] = yval > 255 and 255 or yval
      if y % 2 == 0 and x % 2 == 0 then
        local uval = arshift(-9633 * r - 18940 * g + 28573 * b, 16) + 128
        local vval = arshift(40304 * r - 33750 * g - 6554 * b, 16) + 128
        local uv_idx = (y / 2) * u_stride + (x / 2)
        u_plane[uv_idx] = uval < 0 and 0 or (uval > 255 and 255 or uval)
        v_plane[uv_idx] = vval < 0 and 0 or (vval > 255 and 255 or vval)
      end
    end
  end

  pic.i_pts = self.pts
  self.pts = self.pts + 1
  local ret = self.lib.x264_encoder_encode(self.handle, pp_nal, pi_nal, pic, pic_out)
  if ret > 0 then ffi.C.write(self.file, pp_nal[0].p_payload, ret) end
  return ret
end

function M:flush()
  local pp_nal = ffi.new('x264_nal_t*[1]')
  local pi_nal = ffi.new('int[1]')
  local pic_out, _ = new_safe('x264_picture_t')

  while self.lib.x264_encoder_delayed_frames(self.handle) > 0 do
    local ret = self.lib.x264_encoder_encode(self.handle, pp_nal, pi_nal, nil, pic_out)
    if ret > 0 then ffi.C.write(self.file, pp_nal[0].p_payload, ret) end
  end
end

function M:close()
  if self.handle then
    self:flush()
    if self.pic_in then self.lib.x264_picture_clean(self.pic_in) end
    self.lib.x264_encoder_close(self.handle)
    self.handle = nil
  end
end

return M
