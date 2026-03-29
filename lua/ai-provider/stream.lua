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

local api_registry   = require "ai-provider.api_registry"
local debug_toast    = require "ai-provider.debug_toast"
local notification   = require "ai-provider.notification"

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

local function is_notification_enabled()
  local cfg = require("ai-provider.config").get()
  return cfg.notification == nil or cfg.notification.enabled ~= false
end

--- Build notification lines from a model definition.
---@param model table
---@return string[]
local function notification_lines(model)
  local provider = model.provider or "unknown"
  local id       = model.id or "unknown"
  local host     = (model.base_url or ""):match("^https?://([^/%?]+)") or ""
  local lines    = { "Sending request…", provider .. " / " .. id }
  if host ~= "" then table.insert(lines, "→ " .. host) end
  return lines
end

--- Attach notification spinner (show on start, dismiss on done/error).
---@param es table EventStream
---@param model table
local function attach_notification(es, model)
  if not is_notification_enabled() then return end

  es:on(function(event)
    if event.type == "start" then
      notification.show(notification_lines(model))
    elseif event.type == "done" or event.type == "error" then
      notification.dismiss()
    end
  end)
end

---------------------------------------------------------------------------
-- Debug: save response to file
---------------------------------------------------------------------------

local function attach_debug_log(es, model, context, options)
  if not require("ai-provider.config").get().debug then return end

  local dir = vim.fn.stdpath("cache") .. "/ai-provider-debug"
  vim.fn.mkdir(dir, "p")
  local ts = os.date("%Y%m%d_%H%M%S")
  local path = dir .. "/" .. ts .. ".json"

  es:on(function(event)
    if event.type ~= "done" and event.type ~= "error" then return end
    local msg = event.message or event.error

    local entry = {
      timestamp = ts,
      provider  = model.provider,
      model     = model.id,
      api       = model.api,
      url       = model.base_url,
      options   = options,
      context   = context,
      result    = msg,
    }

    local f = io.open(path, "w")
    if f then
      local ok, json = pcall(vim.json.encode, entry)
      f:write(ok and json or ("encode error: " .. tostring(json)))
      f:close()
    end
  end)
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
  local es = resolve_provider(model).stream(model, context, options)
  attach_notification(es, model)
  attach_debug_log(es, model, context, options)
  debug_toast.attach(es)
  return es
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
  options = options or {}
  -- Apply global default reasoning when not specified per-request
  if options.reasoning == nil then
    local global_reasoning = require("ai-provider.config").get().reasoning
    if global_reasoning then
      options = vim.tbl_extend("force", options, { reasoning = global_reasoning })
    end
  end
  local es = resolve_provider(model).stream_simple(model, context, options)
  attach_notification(es, model)
  attach_debug_log(es, model, context, options)
  debug_toast.attach(es)
  return es
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
