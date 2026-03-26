--- Persistent credential storage for OAuth providers.
--- Credentials are stored as JSON files under stdpath("data")/ai-provider/.
local M = {}

local function get_base_dir()
  return vim.fn.stdpath "data" .. "/ai-provider"
end

local function get_path(provider_name)
  return get_base_dir() .. "/" .. provider_name .. "_credentials.json"
end

--- Read stored credentials for a provider.
---@param provider_name string
---@return table|nil
function M.read(provider_name)
  local path = get_path(provider_name)
  local file = io.open(path, "r")

  if not file then
    return nil
  end

  local content = file:read "*a"
  file:close()

  local ok, data = pcall(vim.json.decode, content)

  if ok and data then
    return data
  end

  return nil
end

--- Persist credentials for a provider.
---@param provider_name string
---@param data table
function M.write(provider_name, data)
  local dir = get_base_dir()
  vim.fn.mkdir(dir, "p")

  local path = get_path(provider_name)
  local file = io.open(path, "w")

  if file then
    file:write(vim.json.encode(data))
    file:close()
  end
end

--- Remove stored credentials for a provider.
---@param provider_name string
function M.clear(provider_name)
  local path = get_path(provider_name)
  os.remove(path)
end

return M
