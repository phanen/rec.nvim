local M = {}
local uv = vim.uv

---@class rec.Thread: uv.luv_thread_t
---@field thread userdata uv_thread
---@field writer userdata uv_pipe
local Thread = {}
Thread.__index = Thread

setmetatable(Thread, {
  __index = function(th, k)
    -- https://github.com/luvit/luv/blob/5cc2a863c6ddf32f93af98314e8d929cc8fd1557/src/thread.c#L602
    local method = uv['thread_' .. k]
    if not method then return end
    rawset(th, k, function(...) return method(th, ...) end)
    return rawget(th, k)
  end,
})

---Spawn a worker thread with pipe communication
---@param entry function function without no upvalue
---@param ... any Additional arguments to pass to worker
---@return rec.Thread?
---@return string?
M.spawn = function(entry, ...)
  local self = setmetatable({}, Thread)

  local fds = assert(uv.pipe({ nonblock = true }, { nonblock = true }))
  self.writer = assert(uv.new_pipe(false))
  assert(self.writer:open(fds.write))

  local err
  self.thread, err = uv.new_thread(
    {},
    function(fd, path, cpath, str, tbl)
      package.path = path
      package.cpath = cpath
      table.insert(package.loaders, 2, vim._load_package)
      if not pcall(require, 'vim._core.editor') then pcall(require, 'vim._editor') end
      local args = require('rec.serialize').decode(tbl)
      return assert(loadstring(str))(fd, unpack(args, 1, args.n)) ---@diagnostic disable-line: undefined-field
    end,
    fds.read,
    package.path,
    package.cpath,
    string.dump(entry),
    require('rec.serialize').encode({ n = select('#', ...), ... })
  )

  return self, err
end

---Write data to worker asynchronously
---@param data string|table Data to write
---@param callback? function
---@return boolean success
function Thread:write(data, callback)
  if self.writer and not self.writer:is_closing() then
    self.writer:write(data, callback)
    return true
  end
  return false
end

---Close thread and writer
function Thread:close()
  if self.writer and not self.writer:is_closing() then
    self.writer:close() -- Sends EOF to worker
    self.writer = nil
  end
  -- We don't join to avoid blocking main thread event loop
  self.thread = nil
end

return M
