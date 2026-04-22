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

local openai_completions      = require "ai-provider.providers.openai_completions"
local openai_responses        = require "ai-provider.providers.openai_responses"
local openai_codex_responses  = require "ai-provider.providers.openai_codex_responses"
local azure_openai_responses  = require "ai-provider.providers.azure_openai_responses"
local anthropic               = require "ai-provider.providers.anthropic"
local google                  = require "ai-provider.providers.google"
local google_gemini_cli       = require "ai-provider.providers.google_gemini_cli"
local google_vertex           = require "ai-provider.providers.google_vertex"
local mistral_conversations   = require "ai-provider.providers.mistral_conversations"
local amazon_bedrock          = require "ai-provider.providers.amazon_bedrock"

api_registry.register("openai-completions", {
  stream        = openai_completions.stream,
  stream_simple = openai_completions.stream_simple,
})
api_registry.register("openai-responses", {
  stream        = openai_responses.stream,
  stream_simple = openai_responses.stream_simple,
})
api_registry.register("openai-codex-responses", {
  stream        = openai_codex_responses.stream,
  stream_simple = openai_codex_responses.stream_simple,
})
api_registry.register("azure-openai-responses", {
  stream        = azure_openai_responses.stream,
  stream_simple = azure_openai_responses.stream_simple,
})
api_registry.register("anthropic-messages", {
  stream        = anthropic.stream,
  stream_simple = anthropic.stream_simple,
})
api_registry.register("google-generative-ai", {
  stream        = google.stream,
  stream_simple = google.stream_simple,
})
api_registry.register("google-gemini-cli", {
  stream        = google_gemini_cli.stream,
  stream_simple = google_gemini_cli.stream_simple,
})
api_registry.register("google-vertex", {
  stream        = google_vertex.stream,
  stream_simple = google_vertex.stream_simple,
})
api_registry.register("mistral-conversations", {
  stream        = mistral_conversations.stream,
  stream_simple = mistral_conversations.stream_simple,
})
api_registry.register("bedrock-converse-stream", {
  stream        = amazon_bedrock.stream,
  stream_simple = amazon_bedrock.stream_simple,
})

return M
