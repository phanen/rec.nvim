local M = {}

local api = vim.api
local font = require('rec.font')
local ffi = require('ffi')

local cached_buffer = nil
local cached_size = 0

---@param width integer
---@param height integer
---@return any, integer
local get_buffer = function(width, height)
  local size = width * height * 3
  if size > cached_size then
    cached_buffer = ffi.new('uint8_t[?]', size)
    cached_size = size
  end
  return cached_buffer, size
end

---@param buffer_ptr any
---@param glyph table
---@param cell_x integer
---@param cell_y integer
---@param cell_w integer
---@param cell_h integer
---@param r integer
---@param g integer
---@param b integer
---@param bg_r integer
---@param bg_g integer
---@param bg_b integer
---@param width integer
---@param height integer
local blend_glyph = function(
  buffer_ptr,
  glyph,
  cell_x,
  cell_y,
  cell_w,
  cell_h,
  r,
  g,
  b,
  bg_r,
  bg_g,
  bg_b,
  width,
  height
)
  local baseline_y = cell_y + math.floor(cell_h * 0.8)
  local x_offset = math.floor((cell_w - glyph.width) / 2)
  local glyph_data = glyph.data

  -- Pre-calculate colors
  local diff_r, diff_g, diff_b = r - bg_r, g - bg_g, b - bg_b

  for gy = 0, glyph.height - 1 do
    local py = baseline_y - glyph.top + gy
    if py >= 0 and py < height then
      local buffer_row_base = py * width * 3
      local glyph_row = glyph_data[gy]

      for gx = 0, glyph.width - 1 do
        local px = cell_x + gx + glyph.left + x_offset
        if px >= 0 and px < width then
          local alpha_val = glyph_row[gx]
          if alpha_val > 0 then
            local idx = buffer_row_base + px * 3
            if alpha_val == 255 then
              buffer_ptr[idx] = r
              buffer_ptr[idx + 1] = g
              buffer_ptr[idx + 2] = b
            else
              -- Integer blending: result = bg + (fg - bg) * alpha / 255
              -- (x * alpha) >> 8 is fast approx for / 255
              -- But we use accurate formula: (x * alpha + 127) / 255 -> (x * alpha + x) >> 8 for 256 scale?
              -- Simple fast approximation: (x * alpha) / 255

              buffer_ptr[idx] = bg_r + math.floor((diff_r * alpha_val) / 255)
              buffer_ptr[idx + 1] = bg_g + math.floor((diff_g * alpha_val) / 255)
              buffer_ptr[idx + 2] = bg_b + math.floor((diff_b * alpha_val) / 255)
            end
          end
        end
      end
    end
  end
end

local default_fg, default_bg

---@param fg? integer
---@return integer
local get_fg = function(fg)
  if fg then return fg end
  default_fg = default_fg or (api.nvim_get_hl(0, { name = 'Normal' }) or {}).fg or 0xc0c0c0
  return default_fg
end

---@param bg? integer
---@return integer
local get_bg = function(bg)
  if bg then return bg end
  default_bg = default_bg or (api.nvim_get_hl(0, { name = 'Normal' }) or {}).bg or 0x000000
  return default_bg
end

---@param color integer
---@return integer, integer, integer
local rgb = function(color)
  local r = math.floor(color / 65536)
  local g = math.floor((color % 65536) / 256)
  local b = math.floor(color) % 256
  return r, g, b
end

---Get RGB components from highlight
---@param hl table
---@return integer, integer, integer
local get_fg_rgb = function(hl) return rgb(get_fg(hl.foreground)) end

---Get RGB components from highlight
---@param hl table
---@return integer, integer, integer
local get_bg_rgb = function(hl) return rgb(get_bg(hl.background)) end

---Render frame with font rendering
---@param frame rec.FrameData
---@param char_w integer
---@param char_h integer
---@return any
M.font = function(frame, char_w, char_h)
  local frame_width = frame.width * char_w
  local frame_height = frame.height * char_h

  local buffer_ptr, buffer_size = get_buffer(frame_width, frame_height)

  -- Fill background roughly first?
  -- No, we iterate cells and fill. But optimization: clear buffer once if assuming mostly background?
  -- Or just overwrite.

  -- Using pointers for writing is much faster than lua table

  for row = 0, frame.height - 1 do
    local row_base_y = row * char_h
    local cell_row = frame.cells[row]

    for col = 0, frame.width - 1 do
      local cell = cell_row and cell_row[col]
      if cell then
        local char, hl = cell[1], cell[2]
        local r, g, b = get_fg_rgb(hl)
        local bg_r, bg_g, bg_b = get_bg_rgb(hl)

        local base_x = col * char_w

        -- Fill cell background
        for py = 0, char_h - 1 do
          local idx = ((row_base_y + py) * frame_width + base_x) * 3
          -- Optimization: fill row segment
          for _ = 0, char_w - 1 do
            buffer_ptr[idx] = bg_r
            buffer_ptr[idx + 1] = bg_g
            buffer_ptr[idx + 2] = bg_b
            idx = idx + 3
          end
        end

        if char ~= ' ' and char ~= '' then
          local glyph = font.render_char(char)
          if glyph then
            blend_glyph(
              buffer_ptr,
              glyph,
              base_x,
              row_base_y,
              char_w,
              char_h,
              r,
              g,
              b,
              bg_r,
              bg_g,
              bg_b,
              frame_width,
              frame_height
            )
          end
        end
      end
    end
  end

  -- Return C pointer directly, x264 encoder handles it
  return buffer_ptr
end

---@param frame rec.FrameData
---@param char_w integer
---@param char_h integer
---@return any
M.pixel = function(frame, char_w, char_h)
  -- Implement pixel rendering using FFI buffer if needed, but font is priority
  -- For now, keep as string or update to buffer
  -- Updating to buffer for consistency
  local frame_width = frame.width * char_w
  local frame_height = frame.height * char_h
  local buffer_ptr = get_buffer(frame_width, frame_height)

  local idx = 0
  for row = 0, frame.height - 1 do
    local cell_row = frame.cells[row]
    for _ = 0, char_h - 1 do
      for col = 0, frame.width - 1 do
        local cell = cell_row and cell_row[col]
        local r, g, b
        if cell then
          local char, hl = cell[1], cell[2]
          if char == ' ' or char == '' then
            r, g, b = get_bg_rgb(hl)
          else
            r, g, b = get_fg_rgb(hl)
          end
        else
          r, g, b = 0, 0, 0
        end

        for _ = 0, char_w - 1 do
          buffer_ptr[idx] = r
          buffer_ptr[idx + 1] = g
          buffer_ptr[idx + 2] = b
          idx = idx + 3
        end
      end
    end
  end
  return buffer_ptr
end

return M
