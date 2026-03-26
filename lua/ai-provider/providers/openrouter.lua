--- OpenRouter provider – API-key based authentication.
local M = {}

local config = require "ai-provider.config"
local models_data = require "ai-provider.models"

--- Resolve the API key from config or environment.
---@return string|nil
function M.get_api_key()
  local cfg = config.get_provider_config "openrouter"
  return cfg.api_key or os.getenv "OPENROUTER_API_KEY"
end

--- Build the chat-completions endpoint URL.
---@return string
function M.get_endpoint()
  local cfg = config.get_provider_config "openrouter"
  local base_url = cfg.url or "https://openrouter.ai/api/v1/"
  local chat_url = cfg.chat_url or "chat/completions"
  return base_url .. chat_url
end

--- Authenticate and call back with (endpoint, headers) or (nil, nil, err).
---@param _model_id string
---@param callback fun(endpoint: string|nil, headers: table|nil, err: string|nil)
function M.prepare_request(_model_id, callback)
  local api_key = M.get_api_key()

  if not api_key then
    callback(nil, nil, "OpenRouter API key not found. Set OPENROUTER_API_KEY env var or api_key in provider config.")
    return
  end

  callback(M.get_endpoint(), {
    content_type = "application/json",
    authorization = "Bearer " .. api_key,
  })
end

--- Login – for key-based providers, just validates the key exists.
---@param callback fun(result: table|nil, err: string|nil)
function M.login(callback)
  local api_key = M.get_api_key()

  if api_key then
    callback { authenticated = true }
  else
    callback(nil, "Set OPENROUTER_API_KEY env var or api_key in provider config.")
  end
end

--- Logout – nothing to clear for key-based auth.
function M.logout()
  vim.notify("OpenRouter uses API key authentication. Remove the OPENROUTER_API_KEY env var to logout.", vim.log.levels.INFO)
end

--- Return current authentication status.
---@return table
function M.status()
  local api_key = M.get_api_key()

  return {
    authenticated = api_key ~= nil,
    provider = "openrouter",
    message = api_key and "API key configured" or "No API key found",
  }
end

--- Return known models.
---@return AiProviderModel[]
function M.get_models()
  return models_data["openrouter"] or {}
end

return M
