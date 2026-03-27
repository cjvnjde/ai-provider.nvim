--- API provider registry.
--- Maps API wire-protocol names to streaming implementations.
--- Mirrors pi-mono packages/ai/src/api-registry.ts.
local M = {}

---@type table<string, { stream: function, stream_simple: function }>
local registry = {}

--- Register an API provider.
---@param api string  API type, e.g. "openai-completions"
---@param provider table  { stream = fn, stream_simple = fn }
function M.register(api, provider)
  assert(provider.stream, "API provider must implement stream()")
  assert(provider.stream_simple, "API provider must implement stream_simple()")
  registry[api] = provider
end

--- Retrieve the provider for an API type.
---@param api string
---@return table|nil
function M.get(api)
  return registry[api]
end

--- List all registered API types.
---@return string[]
function M.list()
  local apis = {}
  for api in pairs(registry) do
    table.insert(apis, api)
  end
  table.sort(apis)
  return apis
end

--- Clear all registrations.
function M.clear()
  registry = {}
end

return M
