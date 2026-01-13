local M = {}
local ffi = require('ffi')

-- FreeType FFI definitions
ffi.cdef([[
typedef signed long FT_Long;
typedef unsigned long FT_ULong;
typedef signed int FT_Int;
typedef unsigned int FT_UInt;
typedef signed short FT_Short;
typedef unsigned short FT_UShort;
typedef signed long FT_Pos;
typedef signed long FT_Fixed;
typedef unsigned char FT_Byte;

// Forward declarations
typedef struct FT_LibraryRec_* FT_Library;
typedef struct FT_FaceRec_* FT_Face;
typedef struct FT_GlyphSlotRec_* FT_GlyphSlot;
typedef struct FT_SubGlyphRec_* FT_SubGlyph;
typedef struct FT_Slot_InternalRec_* FT_Slot_Internal;
typedef struct FT_Size_InternalRec_* FT_Size_Internal;
typedef struct FT_SizeRec_* FT_Size;

typedef struct {
  void* data;
  void* finalizer;
} FT_Generic;

typedef struct {
  FT_Pos x;
  FT_Pos y;
} FT_Vector;

typedef struct {
  FT_Pos xMin, yMin;
  FT_Pos xMax, yMax;
} FT_BBox;

typedef struct {
  unsigned int rows;
  unsigned int width;
  int pitch;
  unsigned char* buffer;
  unsigned short num_grays;
  unsigned char pixel_mode;
  unsigned char palette_mode;
  void* palette;
} FT_Bitmap;

typedef struct {
  short n_contours;
  short n_points;
  FT_Vector* points;
  char* tags;
  short* contours;
  int flags;
} FT_Outline;

typedef struct {
  FT_Pos width;
  FT_Pos height;
  FT_Pos horiBearingX;
  FT_Pos horiBearingY;
  FT_Pos horiAdvance;
  FT_Pos vertBearingX;
  FT_Pos vertBearingY;
  FT_Pos vertAdvance;
} FT_Glyph_Metrics;

typedef enum {
  FT_GLYPH_FORMAT_NONE = 0,
  FT_GLYPH_FORMAT_COMPOSITE = 0x636f6d70,
  FT_GLYPH_FORMAT_BITMAP = 0x62697473,
  FT_GLYPH_FORMAT_OUTLINE = 0x6f75746c,
  FT_GLYPH_FORMAT_PLOTTER = 0x706c6f74
} FT_Glyph_Format;

typedef struct FT_GlyphSlotRec_ {
  FT_Library library;
  FT_Face face;
  FT_GlyphSlot next;
  FT_UInt reserved;
  FT_Generic generic;
  FT_Glyph_Metrics metrics;
  FT_Fixed linearHoriAdvance;
  FT_Fixed linearVertAdvance;
  FT_Vector advance;
  FT_Glyph_Format format;
  FT_Bitmap bitmap;
  FT_Int bitmap_left;
  FT_Int bitmap_top;
  FT_Outline outline;
  FT_UInt num_subglyphs;
  FT_SubGlyph subglyphs;
  void* control_data;
  long control_len;
  FT_Pos lsb_delta;
  FT_Pos rsb_delta;
  void* other;
  FT_Slot_Internal internal;
} FT_GlyphSlotRec;

typedef struct {
  FT_UShort x_ppem;
  FT_UShort y_ppem;
  FT_Fixed x_scale;
  FT_Fixed y_scale;
  FT_Pos ascender;
  FT_Pos descender;
  FT_Pos height;
  FT_Pos max_advance;
} FT_Size_Metrics;

typedef struct FT_SizeRec_ {
  FT_Face face;
  FT_Generic generic;
  FT_Size_Metrics metrics;
  FT_Size_Internal internal;
} FT_SizeRec;

typedef struct FT_FaceRec_ {
  FT_Long num_faces;
  FT_Long face_index;
  FT_Long face_flags;
  FT_Long style_flags;
  FT_Long num_glyphs;
  const char* family_name;
  const char* style_name;
  FT_Int num_fixed_sizes;
  void* available_sizes;
  FT_Int num_charmaps;
  void* charmaps;
  FT_Generic generic;
  FT_BBox bbox;
  FT_UShort units_per_EM;
  FT_Short ascender;
  FT_Short descender;
  FT_Short height;
  FT_Short max_advance_width;
  FT_Short max_advance_height;
  FT_Short underline_position;
  FT_Short underline_thickness;
  FT_GlyphSlot glyph;
  FT_Size size;
  void* charmap;
} FT_FaceRec;

int FT_Init_FreeType(FT_Library* alibrary);
int FT_Done_FreeType(FT_Library library);
int FT_New_Face(FT_Library library, const char* filepathname, FT_Long face_index, FT_Face* aface);
int FT_Done_Face(FT_Face face);
int FT_Set_Pixel_Sizes(FT_Face face, FT_UInt pixel_width, FT_UInt pixel_height);
int FT_Load_Char(FT_Face face, FT_ULong char_code, FT_Int load_flags);
int FT_Load_Glyph(FT_Face face, FT_UInt glyph_index, FT_Int load_flags);
FT_UInt FT_Get_Char_Index(FT_Face face, FT_ULong charcode);
]])

local ft = nil
local load_ok = false
for _, name in ipairs({ 'freetype', 'libfreetype.so.6', 'libfreetype.so' }) do
  load_ok, ft = pcall(ffi.load, name)
  if load_ok then break end
end

if not load_ok or not ft then
  vim.notify('Failed to load freetype library', vim.log.levels.ERROR)
  return M
end

-- Constants
local FT_LOAD_RENDER = 4

---@class rec.FontState
---@field lib ffi.cdata*? FreeType library handle
---@field face ffi.cdata*? FreeType face handle
---@field char_width integer Character width in pixels
---@field char_height integer Character height in pixels

---@type rec.FontState
local state = {
  lib = nil,
  face = nil,
  char_width = 0,
  char_height = 0,
}

---@param font_path string Path to TrueType font file
---@param width integer Character width in pixels
---@param height integer Character height in pixels
---@return boolean success True if initialization succeeded
M.init = function(font_path, width, height)
  if not ft then return false end

  local lib_ptr = ffi.new('FT_Library[1]')
  local err = ft.FT_Init_FreeType(lib_ptr)
  if err ~= 0 then
    vim.notify('FT_Init_FreeType failed: ' .. err, vim.log.levels.ERROR)
    return false
  end
  state.lib = lib_ptr[0]

  local f = io.open(font_path, 'r')
  if not f then
    vim.notify('Font file not found: ' .. font_path, vim.log.levels.ERROR)
    ft.FT_Done_FreeType(state.lib)
    state.lib = nil
    return false
  end
  f:close()

  local face_ptr = ffi.new('FT_Face[1]')
  err = ft.FT_New_Face(state.lib, font_path, 0, face_ptr)
  if err ~= 0 then
    vim.notify('FT_New_Face failed: ' .. err, vim.log.levels.ERROR)
    ft.FT_Done_FreeType(state.lib)
    state.lib = nil
    return false
  end
  state.face = face_ptr[0]

  err = ft.FT_Set_Pixel_Sizes(state.face, width, height)
  if err ~= 0 then
    vim.notify('FT_Set_Pixel_Sizes failed: ' .. err, vim.log.levels.ERROR)
    ft.FT_Done_Face(state.face)
    ft.FT_Done_FreeType(state.lib)
    state.face = nil
    state.lib = nil
    return false
  end

  -- Test load a character to verify everything works
  err = ft.FT_Load_Char(state.face, string.byte('A'), FT_LOAD_RENDER)
  if err ~= 0 then
    vim.notify('Test load failed: ' .. err, vim.log.levels.ERROR)
    ft.FT_Done_Face(state.face)
    ft.FT_Done_FreeType(state.lib)
    state.face = nil
    state.lib = nil
    return false
  end

  state.char_width = width
  state.char_height = height
  return true
end

---@param char string
---@return table?
M.render_char = function(char)
  local face = state.face
  if not face then
    vim.notify('render_char: face is nil', vim.log.levels.WARN)
    return
  end

  if not char or char == '' then return end

  local code = string.byte(char)
  if not code then return end

  local err = ft.FT_Load_Char(face, code, FT_LOAD_RENDER)
  if err ~= 0 then
    -- Don't spam for missing glyphs, just return silently
    return
  end

  -- Use pcall to catch any segfaults during structure access
  local ok, result = pcall(function()
    -- Cast face to access the glyph slot
    -- IMPORTANT: face is already FT_Face (pointer), we need to dereference it
    local face_rec = ffi.cast('FT_FaceRec*', face)
    if face_rec == nil then error('face_rec cast failed') end

    local glyph = face_rec.glyph
    if glyph == nil then error('glyph is nil') end

    -- Dereference glyph slot to access bitmap
    local glyph_rec = ffi.cast('FT_GlyphSlotRec*', glyph)
    if glyph_rec == nil then error('glyph_rec cast failed') end

    local bitmap = glyph_rec.bitmap

    if bitmap.buffer == nil then error('bitmap.buffer is nil') end

    local width = tonumber(bitmap.width)
    local height = tonumber(bitmap.rows)
    local pitch = math.abs(tonumber(bitmap.pitch))

    if width == 0 or height == 0 then error('bitmap dimensions are zero') end

    -- Copy bitmap data
    local data = {}
    for y = 0, height - 1 do
      data[y] = {}
      for x = 0, width - 1 do
        local idx = y * pitch + x
        data[y][x] = bitmap.buffer[idx]
      end
    end

    return {
      width = width,
      height = height,
      left = tonumber(glyph_rec.bitmap_left),
      top = tonumber(glyph_rec.bitmap_top),
      data = data,
    }
  end)

  if not ok then
    -- Log error but don't notify to avoid spam
    -- vim.notify('render_char error: ' .. tostring(result), vim.log.levels.ERROR)
    return
  end

  return result
end

M.cleanup = function()
  if state.face and ft then pcall(ft.FT_Done_Face, state.face) end
  if state.lib and ft then pcall(ft.FT_Done_FreeType, state.lib) end
  state.face = nil
  state.lib = nil
end

return M
