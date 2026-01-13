---@class rec.serializer
---@field encode fun(data: any): string
---@field decode fun(data: any): string

---@type rec.serializer
local mpack = {
  encode = vim.mpack.encode,
  decode = vim.mpack.decode,
}

---@type rec.serializer
local json = {
  encode = vim.json.encode,
  decode = vim.json.decode,
}

local impls = {
  mpack = mpack,
  json = json,
}

-- cjson is faster, but cannot encode "array-table"
return impls.mpack
