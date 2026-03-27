--- Top-level streaming API.
---
--- Mirrors pi-mono packages/ai/src/stream.ts.
---
--- Usage:
---   local ai = require("ai-provider")
---   local model = ai.get_model("openrouter", "anthropic/claude-sonnet-4")
---   local es = ai.stream(model, { system_prompt = "...", messages = {...} })
---   es:on(function(event) print(event.type) end)
---   es:on_done(function(msg) print("Done!", msg.model) end)
local M = {}

local api_registry = require "ai-provider.api_registry"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function resolve_provider(model)
  local provider = api_registry.get(model.api)
  if not provider then
    error("No API provider registered for api: " .. tostring(model.api))
  end
  return provider
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Stream a request with provider-specific options.
---
---@param model table   Rich model from models.lua
---@param context table { system_prompt?: string, messages: Message[], tools?: Tool[] }
---@param options? table Provider-specific options
---@return EventStream
function M.stream(model, context, options)
  return resolve_provider(model).stream(model, context, options)
end

--- Complete (non-streaming convenience) – returns the final message via callback.
---
---@param model table
---@param context table
---@param options? table
---@param callback fun(message: table)
function M.complete(model, context, options, callback)
  M.stream(model, context, options):result(callback)
end

--- Stream with unified reasoning option.
---
---@param model table
---@param context table
---@param options? table { reasoning?: "minimal"|"low"|"medium"|"high", temperature?, max_tokens?, ... }
---@return EventStream
function M.stream_simple(model, context, options)
  return resolve_provider(model).stream_simple(model, context, options)
end

--- Complete (non-streaming) with unified reasoning option.
---
---@param model table
---@param context table
---@param options? table
---@param callback fun(message: table)
function M.complete_simple(model, context, options, callback)
  M.stream_simple(model, context, options):result(callback)
end

return M
