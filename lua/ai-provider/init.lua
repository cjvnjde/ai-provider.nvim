--- ai-provider – reusable AI provider abstraction for Neovim plugins.
---
--- Supports multiple providers (Anthropic, Google, OpenAI direct +
--- Responses API, Azure OpenAI Responses, OpenRouter, GitHub Copilot,
--- xAI, Groq, Cerebras, z.ai, Mistral conversations, Vercel AI Gateway,
--- Hugging Face, Fireworks, Opencode, Kimi, etc.) with:
--- - SSE streaming with event callbacks
--- - Unified reasoning/thinking configuration (incl. `xhigh`)
--- - Rich model definitions with cost & capability metadata
--- - OAuth (Copilot + Anthropic sk-ant-oat) and API-key authentication
--- - Prompt caching (Anthropic-native and OpenAI prompt_cache_*)
--- - Session affinity / x-affinity header propagation
--- - `on_payload` / `on_response` / `metadata.user_id` passthrough
---
--- Streaming usage (new):
---   local ai = require("ai-provider")
---   ai.setup({ providers = { openrouter = { api_key = "sk-..." } } })
---   local model = ai.get_model("openrouter", "anthropic/claude-sonnet-4")
---   local es = ai.stream_simple(model, {
---     system_prompt = "You are helpful.",
---     messages = {{ role = "user", content = "Hi!" }},
---   }, { reasoning = "medium" })
---   es:on(function(event)
---     if event.type == "text_delta" then io.write(event.delta) end
---   end)
---   es:on_done(function(msg) print("\nDone! Tokens:", msg.usage.total_tokens) end)
---   es:on_error(function(msg) print("Error:", msg.error_message) end)
---
--- Legacy usage (still works):
---   ai.request({ provider = "openrouter", model = "gpt-4o", body = {...} }, callback)
local M = {}

local cfg = require "ai-provider.config"
local provider_registry = require "ai-provider.providers"
local request_mod = require "ai-provider.request"
local stream_mod = require "ai-provider.stream"
local models_data = require "ai-provider.models"
local api_registry = require "ai-provider.api_registry"

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Configure provider settings.
---
--- @param opts? table
---   - providers: table<string, table>  Provider-specific settings (api_key, etc.)
---   - reasoning: string|nil            Default reasoning level
---   - custom_models: table|nil         Custom model definitions { provider = { model, ... } }
function M.setup(opts)
  cfg.setup(opts)
end

---------------------------------------------------------------------------
-- Auth
---------------------------------------------------------------------------

--- Start the login flow for a provider.
---@param provider_name string
---@param callback? fun(result: table|nil, err: string|nil)
function M.login(provider_name, callback)
  local provider = provider_registry.get(provider_name)
  if not provider then
    local msg = "Unknown provider: " .. tostring(provider_name)
    vim.notify(msg, vim.log.levels.ERROR)
    if callback then callback(nil, msg) end
    return
  end
  provider.login(callback or function(_, err)
    if err then
      vim.notify("Login failed: " .. err, vim.log.levels.ERROR)
    else
      vim.notify(provider_name .. ": login successful!", vim.log.levels.INFO)
    end
  end)
end

--- Clear stored credentials for a provider.
---@param provider_name string
function M.logout(provider_name)
  local provider = provider_registry.get(provider_name)
  if not provider then
    vim.notify("Unknown provider: " .. tostring(provider_name), vim.log.levels.ERROR)
    return
  end
  provider.logout()
end

--- Return authentication / connection status for a provider.
---@param provider_name string
---@return table
function M.status(provider_name)
  local provider = provider_registry.get(provider_name)
  if not provider then
    return { authenticated = false, provider = provider_name, message = "Unknown provider" }
  end
  return provider.status()
end

---------------------------------------------------------------------------
-- Models
---------------------------------------------------------------------------

--- Return the list of known models for a provider (rich model definitions).
---@param provider_name string
---@return table[]
function M.get_models(provider_name)
  return models_data.get_models(provider_name)
end

--- Retrieve a specific model by provider and model ID.
---@param provider_name string
---@param model_id string
---@return table|nil
function M.get_model(provider_name, model_id)
  return models_data.get_model(provider_name, model_id)
end

--- List all provider names that have model definitions.
---@return string[]
function M.get_providers()
  return models_data.get_providers()
end

---------------------------------------------------------------------------
-- Streaming API (new)
---------------------------------------------------------------------------

--- Stream a request with provider-specific options.
---
---@param model table   Rich model from get_model() / get_models()
---@param context table { system_prompt?: string, messages: Message[], tools?: Tool[] }
---@param options? table Provider-specific options (api_key, temperature, max_tokens, ...)
---@return EventStream
function M.stream(model, context, options)
  return stream_mod.stream(model, context, options)
end

--- Stream with unified reasoning option.
---
---@param model table
---@param context table
---@param options? table { reasoning?: "minimal"|"low"|"medium"|"high", ... }
---@return EventStream
function M.stream_simple(model, context, options)
  return stream_mod.stream_simple(model, context, options)
end

--- Complete (non-streaming) with provider-specific options.
---
---@param model table
---@param context table
---@param options? table
---@param callback fun(message: table)
function M.complete(model, context, options, callback)
  stream_mod.complete(model, context, options, callback)
end

--- Complete (non-streaming) with unified reasoning option.
---
---@param model table
---@param context table
---@param options? table
---@param callback fun(message: table)
function M.complete_simple(model, context, options, callback)
  stream_mod.complete_simple(model, context, options, callback)
end

---------------------------------------------------------------------------
-- Auth providers & API registry (advanced)
---------------------------------------------------------------------------

--- Register a custom auth provider (login/logout/status/get_models).
---@param name string
---@param provider table
function M.register_provider(name, provider)
  provider_registry.register(name, provider)
end

--- Register a custom API streaming provider.
---@param api string  API type name (e.g., "my-custom-api")
---@param provider table  { stream = fn, stream_simple = fn }
function M.register_api(api, provider)
  api_registry.register(api, provider)
end

--- List all registered API types.
---@return string[]
function M.get_apis()
  return api_registry.list()
end

---------------------------------------------------------------------------
-- Legacy request API (backward compatible)
---------------------------------------------------------------------------

--- Send a chat-completion request through a provider (non-streaming).
---
---@param opts table { provider: string, model: string, body: table }
---@param callback fun(response: table|nil, err: string|nil)
function M.request(opts, callback)
  request_mod.send(opts, callback)
end

---------------------------------------------------------------------------
-- Re-exports for convenience
---------------------------------------------------------------------------

M.EventStream  = require "ai-provider.event_stream"
M.types        = require "ai-provider.types"
M.env_keys     = require "ai-provider.env_keys"
M.utils        = require "ai-provider.utils"
M.debug_toast  = require "ai-provider.debug_toast"

return M
