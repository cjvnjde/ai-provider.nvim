--- OpenAI Responses API streaming provider.
---
--- Covers: OpenAI direct, GitHub Copilot (GPT-5.x), any other
---         `/v1/responses`-compatible endpoint.
---
--- Mirrors pi-mono packages/ai/src/providers/openai-responses.ts.
local M = {}

local EventStream = require "ai-provider.event_stream"
local curl_stream = require "ai-provider.curl_stream"
local types       = require "ai-provider.types"
local env_keys    = require "ai-provider.env_keys"
local shared      = require "ai-provider.providers.openai_responses_shared"

local OPENAI_TOOL_CALL_PROVIDERS = { "openai", "openai-codex", "opencode" }

local function resolve_cache_retention(cache_retention)
  if cache_retention then return cache_retention end
  if os.getenv("PI_CACHE_RETENTION") == "long" then return "long" end
  return "short"
end

local function get_prompt_cache_retention(base_url, cache_retention)
  if cache_retention ~= "long" then return nil end
  if base_url and base_url:find("api%.openai%.com") then return "24h" end
  return nil
end

local function service_tier_cost_multiplier(tier)
  if tier == "flex" then return 0.5 end
  if tier == "priority" then return 2 end
  return 1
end

local function apply_service_tier_pricing(usage, tier)
  local m = service_tier_cost_multiplier(tier)
  if m == 1 or not usage or not usage.cost then return end
  usage.cost.input = usage.cost.input * m
  usage.cost.output = usage.cost.output * m
  usage.cost.cache_read = usage.cost.cache_read * m
  usage.cost.cache_write = usage.cost.cache_write * m
  usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write
end

local function build_headers(model, context, api_key, options, session_id)
  local h = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. api_key,
    ["Accept"] = "text/event-stream",
  }

  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end

  if model.provider == "github-copilot" then
    local copilot_headers = require("ai-provider.providers.copilot").build_dynamic_headers(context.messages)
    for k, v in pairs(copilot_headers) do h[k] = v end
  end

  if session_id then
    h["session_id"] = session_id
    h["x-client-request-id"] = session_id
  end

  if options and options.headers then
    for k, v in pairs(options.headers) do h[k] = v end
  end
  return h
end

local function build_body(model, context, options)
  options = options or {}
  local cache_retention = resolve_cache_retention(options.cache_retention)
  local messages = shared.convert_messages(model, context, OPENAI_TOOL_CALL_PROVIDERS)

  local body = {
    model = model.id,
    input = messages,
    stream = true,
    prompt_cache_key = cache_retention ~= "none" and options.session_id or nil,
    prompt_cache_retention = get_prompt_cache_retention(model.base_url, cache_retention),
    store = false,
  }

  if options.max_tokens then body.max_output_tokens = options.max_tokens end
  if options.temperature ~= nil then body.temperature = options.temperature end
  if options.service_tier ~= nil then body.service_tier = options.service_tier end

  if context.tools and #context.tools > 0 then
    body.tools = shared.convert_tools(context.tools)
  end

  if model.reasoning then
    if options.reasoning_effort or options.reasoning_summary then
      body.reasoning = {
        effort = options.reasoning_effort or "medium",
        summary = options.reasoning_summary or "auto",
      }
      body.include = { "reasoning.encrypted_content" }
    elseif model.provider ~= "github-copilot" then
      body.reasoning = { effort = "none" }
    end
  end

  -- Optional caller payload hook.
  if options.on_payload then
    local next_body = options.on_payload(body, model)
    if next_body ~= nil then body = next_body end
  end

  return body
end

local function resolve_api_key(model, options)
  if options and options.api_key then return options.api_key end
  local cfg = require("ai-provider.config").get_provider_config(model.provider)
  if cfg and cfg.api_key then return cfg.api_key end
  local key = env_keys.get(model.provider)
  if key then return key end
  if model.provider == "github-copilot" then
    local creds = require("ai-provider.credential_store").read("github-copilot")
    if creds and creds.access_token then return creds.access_token end
  end
  return nil
end

--- Core stream.
---@param model table
---@param context table
---@param options? table
---@return EventStream
function M.stream(model, context, options)
  options = options or {}
  local es = EventStream.new()

  vim.schedule(function()
    local function auth_error(err)
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = err or ("No API key for provider: " .. model.provider)
      es:push({ type = "error", reason = "error", error = out })
      es:finish()
    end

    local function start_request(api_key, resolved_base_url)
      local base_url = resolved_base_url or model.base_url
      if base_url:sub(-1) == "/" then base_url = base_url:sub(1, -2) end
      local endpoint = base_url .. "/responses"

      local cache_retention = resolve_cache_retention(options.cache_retention)
      local session_id = (cache_retention ~= "none") and options.session_id or nil
      local headers = build_headers(model, context, api_key, options, session_id)
      local body    = build_body(model, context, options)

      local output = types.new_assistant_message(model)
      local state  = shared.new_state(model, output, es, {
        service_tier = options.service_tier,
        apply_service_tier_pricing = apply_service_tier_pricing,
      })
      local got_sse, error_chunks = false, {}

      es:push({ type = "start", partial = output })

      local job_id = curl_stream.stream({
        url = endpoint,
        headers = headers,
        body = body,
        on_event = function(event_type, data)
          if es:is_done() then return end
          got_sse = true
          local ok, evt = pcall(vim.json.decode, data)
          if not ok then table.insert(error_chunks, data); return end
          -- SSE wire can deliver event: response.created / data: {...}
          -- OR a single JSON object carrying { type: ..., ... }. In the
          -- former case evt.type already reflects the event name; in the
          -- latter we inject it from the SSE event name.
          if not evt.type and event_type then evt.type = event_type end

          if evt.error and not evt.type then
            output.stop_reason = "error"
            output.error_message = evt.error.message or vim.json.encode(evt.error)
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end

          local err = shared.process_event(evt, state)
          if err then
            output.stop_reason = "error"
            output.error_message = err
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end
        end,
        on_error = function(err)
          if es:is_done() then return end
          output.stop_reason = "error"; output.error_message = err
          es:push({ type = "error", reason = "error", error = output })
          es:finish()
        end,
        on_done = function()
          if es:is_done() then return end
          if not got_sse and #error_chunks > 0 then
            local raw = table.concat(error_chunks, "\n")
            local eok, edata = pcall(vim.json.decode, raw)
            output.stop_reason = "error"
            output.error_message = (eok and edata and edata.error and edata.error.message) or raw
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end
          if output.stop_reason == "error" or output.stop_reason == "aborted" then
            es:push({ type = "error", reason = output.stop_reason, error = output })
          else
            es:push({ type = "done", reason = output.stop_reason, message = output })
          end
          es:finish()
        end,
      })
      es:set_job_id(job_id)
    end

    if model.provider == "github-copilot" then
      local provider_cfg = require("ai-provider.config").get_provider_config(model.provider) or {}
      local token_override = (options and options.api_key) or provider_cfg.api_key or env_keys.get(model.provider)
      require("ai-provider.providers.copilot").get_token(function(token, base_url, err)
        if token then start_request(token, base_url) else auth_error(err) end
      end, token_override)
      return
    end

    local api_key = resolve_api_key(model, options)
    if not api_key then auth_error() return end
    start_request(api_key, model.base_url)
  end)

  return es
end

--- Simplified stream with unified reasoning option.
---@param model table
---@param context table
---@param options? table
---@return EventStream
function M.stream_simple(model, context, options)
  options = options or {}
  local base = {
    api_key         = options.api_key,
    temperature     = options.temperature,
    max_tokens      = options.max_tokens or (model.max_tokens and math.min(model.max_tokens, 32000) or nil),
    headers         = options.headers,
    cache_retention = options.cache_retention,
    session_id      = options.session_id,
    on_payload      = options.on_payload,
    on_response     = options.on_response,
    metadata        = options.metadata,
    service_tier    = options.service_tier,
  }
  if options.reasoning then
    -- GPT-5.2/5.3/5.4 natively support "xhigh"; others clamp to "high".
    base.reasoning_effort = types.supports_xhigh(model) and options.reasoning or types.clamp_reasoning(options.reasoning)
  end
  return M.stream(model, context, base)
end

return M
