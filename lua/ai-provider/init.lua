--- ai-provider – reusable AI provider abstraction for Neovim plugins.
---
--- Supports API-key providers (OpenRouter) and OAuth providers (GitHub Copilot).
--- Handles authentication, model discovery, and HTTP requests.
---
--- Usage:
---   local ai = require("ai-provider")
---   ai.setup({ providers = { openrouter = { api_key = "sk-..." } } })
---   ai.get_models("github-copilot")
---   ai.request({ provider = "github-copilot", model = "gpt-4o", body = {…} }, callback)
local M = {}

local cfg = require "ai-provider.config"
local provider_registry = require "ai-provider.providers"
local request = require "ai-provider.request"

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Configure provider settings.  Optional – sane defaults work out of the box.
---
--- @param opts? table { providers = { openrouter = {…}, ["github-copilot"] = {…} } }
function M.setup(opts)
  cfg.setup(opts)
end

---------------------------------------------------------------------------
-- Auth
---------------------------------------------------------------------------

--- Start the login flow for a provider.
--- For key-based providers this simply validates the key.
--- For OAuth providers this triggers the device-code / browser flow.
---
--- @param provider_name string
--- @param callback? fun(result: table|nil, err: string|nil)
function M.login(provider_name, callback)
  local provider = provider_registry.get(provider_name)

  if not provider then
    local msg = "Unknown provider: " .. tostring(provider_name)
    vim.notify(msg, vim.log.levels.ERROR)
    if callback then
      callback(nil, msg)
    end
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
--- @param provider_name string
function M.logout(provider_name)
  local provider = provider_registry.get(provider_name)

  if not provider then
    vim.notify("Unknown provider: " .. tostring(provider_name), vim.log.levels.ERROR)
    return
  end

  provider.logout()
end

--- Return authentication / connection status for a provider.
--- @param provider_name string
--- @return table { authenticated: bool, provider: string, message: string }
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

--- Return the list of known models for a provider.
--- @param provider_name string
--- @return AiProviderModel[]
function M.get_models(provider_name)
  local provider = provider_registry.get(provider_name)

  if not provider then
    return {}
  end

  return provider.get_models()
end

---------------------------------------------------------------------------
-- Providers
---------------------------------------------------------------------------

--- List all registered provider names.
--- @return string[]
function M.get_providers()
  return provider_registry.list()
end

--- Register a custom provider implementation.
--- @param name string
--- @param provider table Must implement prepare_request, login, logout, status, get_models
function M.register_provider(name, provider)
  provider_registry.register(name, provider)
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

--- Send a chat-completion request through a provider.
---
--- @param opts table { provider: string, model: string, body: table }
--- @param callback fun(response: table|nil, err: string|nil)
function M.request(opts, callback)
  request.send(opts, callback)
end

return M
