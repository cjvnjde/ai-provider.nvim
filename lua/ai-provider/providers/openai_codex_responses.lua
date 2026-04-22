--- OpenAI Codex Responses (openai-codex-responses) — uses the same
--- `/responses` wire protocol as openai-responses but authenticates via
--- the `openai-codex` provider's OAuth device-code flow (ChatGPT account
--- login, ~/.openai/auth.json) rather than an OPENAI_API_KEY.
---
--- ai-provider.nvim does not implement the Codex OAuth flow (pi-mono's
--- `oauth/openai-codex` helper is ~400 LOC). If you already have a valid
--- Codex access_token somewhere you can pass it via `options.api_key`, in
--- which case this provider delegates to the plain `openai-responses`
--- provider.
local M = {}

local EventStream = require "ai-provider.event_stream"
local types       = require "ai-provider.types"
local responses   = require "ai-provider.providers.openai_responses"

local function needs_login(model)
  local es = EventStream.new()
  vim.schedule(function()
    local out = types.new_assistant_message(model)
    out.stop_reason = "error"
    out.error_message = "openai-codex device-code OAuth is not implemented "
      .. "in ai-provider.nvim. Pass a pre-obtained access token via "
      .. "options.api_key, or run pi-mono."
    es:push({ type = "error", reason = "error", error = out })
    es:finish()
  end)
  return es
end

local function has_token(options)
  return options and options.api_key and options.api_key ~= ""
end

function M.stream(model, context, options)
  if has_token(options) then return responses.stream(model, context, options) end
  return needs_login(model)
end

function M.stream_simple(model, context, options)
  if has_token(options) then return responses.stream_simple(model, context, options) end
  return needs_login(model)
end

return M
