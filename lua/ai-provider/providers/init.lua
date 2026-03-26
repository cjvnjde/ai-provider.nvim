--- Provider registry – discovers and returns provider implementations.
local M = {}

---@type table<string, table>
local providers = {}

--- Register a provider implementation.
---@param name string
---@param provider table
function M.register(name, provider)
  providers[name] = provider
end

--- Retrieve a provider by name.
---@param name string
---@return table|nil
function M.get(name)
  return providers[name]
end

--- List all registered provider names.
---@return string[]
function M.list()
  local names = {}
  for name, _ in pairs(providers) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

-- Register built-in providers
M.register("openrouter", require "ai-provider.providers.openrouter")
M.register("github-copilot", require "ai-provider.providers.copilot")

return M
