-- A high-level client for interacting with the Neovim RPC API.

local Session = require('rec.rpc.session')
local SocketStream = require('rec.rpc.uv_stream').SocketStream

---@class rec.Client
local Client = {}
Client.__index = Client
if false then
  Client.api = vim.api
  Client.fn = vim.fn
end

--- Creates a proxy table that dynamically generates functions for API calls.
-- This allows for a natural syntax like `client.api.nvim_get_current_buf()`.
---@param call_func function The function to execute when an API method is called.
---@return table A metatable that intercepts index access.
local create_callindex = function(call_func)
  return setmetatable({}, {
    ---@param tbl table<any, function>
    ---@param method_name string The name of the API method (e.g., "nvim_get_current_buf").
    ---@return function
    __index = function(tbl, method_name)
      local generated_func = function(...) return select(2, assert(call_func(method_name, ...))) end
      -- Cache the generated function for future calls.
      tbl[method_name] = generated_func
      return generated_func
    end,
  })
end

--- Creates a new Client instance. This is called by `M.connect`.
---@param stream table The stream object from uv_stream.lua.
---@return rec.Client The new client instance.
function Client.new(stream)
  local session = Session.new(stream)

  local self = setmetatable({
    _session = session,
  }, Client)

  -- Create proxies for Neovim API namespaces
  self.api = create_callindex(function(method, ...)
    -- Forward to the session's request method, unpacking arguments.
    return self:request(method, ...)
  end)

  self.fn = create_callindex(function(func_name, ...)
    -- nvim_call_function expects arguments to be in a table.
    return self:request('nvim_call_function', func_name, { ... })
  end)

  return self
end

--- Sends an RPC request and waits for the response.
---@param method string The RPC method name.
---@param ... any Arguments for the method.
---@return boolean, any Success status and result or error.
function Client:request(method, ...) return self._session:request(method, ...) end

--- Sends an RPC notification without waiting for a response.
---@param method string The RPC method name.
---@param ... any Arguments for the method.
function Client:notify(method, ...) self._session:notify(method, ...) end

--- Closes the RPC session and the underlying stream.
function Client:close() self._session:close() end

-- =============================================================================
-- Public Module Interface
-- =============================================================================
local M = {}

--- Creates a new Client connected by a domain socket (named pipe) or TCP.
---@param file_or_address string The named pipe path or a "host:port" string.
---@return rec.Client The new client instance.
M.connect = function(file_or_address)
  local addr, port = string.match(file_or_address, '(.*):(%d+)')
  local stream = (addr and port) and SocketStream.connect(addr, tonumber(port))
    or SocketStream.open(file_or_address)
  return Client.new(stream)
end

return M
