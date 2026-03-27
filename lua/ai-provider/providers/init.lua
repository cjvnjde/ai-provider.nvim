--- Provider registry – authentication providers + API streaming providers.
---
--- This module registers:
--- 1. "auth providers" keyed by provider name  (login, logout, status, get_models)
--- 2. "API providers" keyed by API type         (stream, stream_simple)
local M = {}

local api_registry = require "ai-provider.api_registry"

---------------------------------------------------------------------------
-- Auth-provider registry (existing – login/logout/status/get_models)
---------------------------------------------------------------------------

---@type table<string, table>
local auth_providers = {}

--- Register an auth provider implementation.
---@param name string
---@param provider table
function M.register(name, provider)
  auth_providers[name] = provider
end

--- Retrieve an auth provider by name.
---@param name string
---@return table|nil
function M.get(name)
  return auth_providers[name]
end

--- List all registered auth provider names.
---@return string[]
function M.list()
  local names = {}
  for name in pairs(auth_providers) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

---------------------------------------------------------------------------
-- Register built-in auth providers
---------------------------------------------------------------------------

M.register("openrouter", require "ai-provider.providers.openrouter")
M.register("github-copilot", require "ai-provider.providers.copilot")

---------------------------------------------------------------------------
-- Register built-in API streaming providers
---------------------------------------------------------------------------

local openai_completions = require "ai-provider.providers.openai_completions"
local anthropic          = require "ai-provider.providers.anthropic"
local google             = require "ai-provider.providers.google"

api_registry.register("openai-completions", {
  stream        = openai_completions.stream,
  stream_simple = openai_completions.stream_simple,
})

api_registry.register("anthropic-messages", {
  stream        = anthropic.stream,
  stream_simple = anthropic.stream_simple,
})

api_registry.register("google-generative-ai", {
  stream        = google.stream,
  stream_simple = google.stream_simple,
})

return M
