local api = vim.api
local M = {}

local exec_lua = vim.is_thread() and function(code, ...) return api.nvim_exec_lua(code, { ... }) end
  or function(code, ...) return assert(loadstring(code))(...) end

---@class rec.FrameData
---@field width integer
---@field height integer
---@field cells rec.CellData[][]

---@class rec.CellData
---@field [1] string char
---@field [2] table highlight

---@return integer, integer
M.size = function()
  return api.nvim_get_option_value('columns', {}), api.nvim_get_option_value('lines', {})
end

--- Captures the entire screen by inspecting each cell via a single atomic RPC call.
---@param grid? integer The grid id to capture, defaults to 0.
---@return rec.FrameData A table containing the screen dimensions and cell data.
M.grid = function(grid)
  local cols, lines = M.size()
  local cells = exec_lua(
    [[
      local cells, cols, lines, grid = {}, ...
      for row = 1, lines do
        cells[row] = {}
        local line = cells[row]
        for col = 1, cols do
          local cell = vim.F.npcall(vim.api.nvim__inspect_cell, grid, row - 1, col - 1)
          line[col] = cell and { cell[1] or ' ', cell[2] or {} } or { ' ', {} }
        end
      end
      return cells
    ]],
    cols or 0,
    lines or 0,
    grid or 1
  )
  return { width = cols, height = lines, cells = cells }
end

return M
