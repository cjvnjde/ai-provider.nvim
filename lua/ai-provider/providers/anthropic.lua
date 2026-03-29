--- Anthropic Messages API streaming provider.
---
--- Covers: Anthropic direct, GitHub Copilot (Claude models).
--- Handles extended thinking (budget-based and adaptive).
---
--- Mirrors pi-mono packages/ai/src/providers/anthropic.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"

---------------------------------------------------------------------------
-- Stop-reason mapping
---------------------------------------------------------------------------

local function map_stop_reason(reason)
  if reason == "end_turn" then return "stop" end
  if reason == "max_tokens" then return "length" end
  if reason == "tool_use" then return "toolUse" end
  if reason == "refusal" or reason == "sensitive" then return "error" end
  if reason == "pause_turn" or reason == "stop_sequence" then return "stop" end
  return "error"
end

---------------------------------------------------------------------------
-- Adaptive-thinking helpers
---------------------------------------------------------------------------

local function supports_adaptive(model_id)
  return model_id:find("opus%-4%.6") or model_id:find("opus%-4%-6")
      or model_id:find("sonnet%-4%.6") or model_id:find("sonnet%-4%-6")
end

local function map_thinking_level_to_effort(level, model_id)
  if level == "minimal" or level == "low" then return "low" end
  if level == "medium" then return "medium" end
  if level == "xhigh" and (model_id:find("opus%-4%.6") or model_id:find("opus%-4%-6")) then return "max" end
  return "high"
end

---------------------------------------------------------------------------
-- Message conversion
---------------------------------------------------------------------------

local function convert_messages(messages, model, is_copilot)
  local params = {}

  for _, msg in ipairs(messages) do
    if msg.role == "user" then
      if type(msg.content) == "string" then
        if #msg.content > 0 then
          table.insert(params, { role = "user", content = msg.content })
        end
      else
        local blocks = {}
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(blocks, { type = "text", text = item.text })
          elseif item.type == "image" then
            table.insert(blocks, {
              type = "image",
              source = {
                type = "base64",
                media_type = item.mime_type,
                data = item.data,
              },
            })
          end
        end
        if #blocks > 0 then
          table.insert(params, { role = "user", content = blocks })
        end
      end

    elseif msg.role == "assistant" then
      local blocks = {}
      for _, block in ipairs(msg.content) do
        if block.type == "text" and block.text and #vim.trim(block.text) > 0 then
          table.insert(blocks, { type = "text", text = block.text })
        elseif block.type == "thinking" then
          if block.redacted then
            table.insert(blocks, { type = "redacted_thinking", data = block.thinking_signature })
          elseif block.thinking and #vim.trim(block.thinking) > 0 then
            if block.thinking_signature and #block.thinking_signature > 0 then
              table.insert(blocks, {
                type = "thinking",
                thinking = block.thinking,
                signature = block.thinking_signature,
              })
            else
              table.insert(blocks, { type = "text", text = block.thinking })
            end
          end
        elseif block.type == "toolCall" then
          table.insert(blocks, {
            type = "tool_use",
            id = block.id,
            name = block.name,
            input = block.arguments or {},
          })
        end
      end
      if #blocks > 0 then
        table.insert(params, { role = "assistant", content = blocks })
      end

    elseif msg.role == "toolResult" then
      local text = ""
      if msg.content then
        for _, c in ipairs(msg.content) do
          if c.type == "text" then text = text .. c.text end
        end
      end
      table.insert(params, {
        role = "user",
        content = {
          {
            type = "tool_result",
            tool_use_id = msg.tool_call_id,
            content = text ~= "" and text or "(empty)",
            is_error = msg.is_error or false,
          },
        },
      })
    end
  end
  return params
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

local function convert_tools(tools)
  if not tools or #tools == 0 then return nil end
  local out = {}
  for _, tool in ipairs(tools) do
    local schema = tool.parameters or {}
    table.insert(out, {
      name = tool.name,
      description = tool.description,
      input_schema = {
        type = "object",
        properties = schema.properties or {},
        required = schema.required or {},
      },
    })
  end
  return out
end

---------------------------------------------------------------------------
-- Build request
---------------------------------------------------------------------------

local function build_body(model, context, options)
  options = options or {}
  local body = {
    model = model.id,
    messages = convert_messages(context.messages, model, model.provider == "github-copilot"),
    max_tokens = options.max_tokens or math.floor(model.max_tokens / 3),
    stream = true,
  }

  -- System prompt
  if context.system_prompt then
    body.system = { { type = "text", text = context.system_prompt } }
  end

  -- Temperature (incompatible with thinking)
  if options.temperature and not options.thinking_enabled then
    body.temperature = options.temperature
  end

  -- Tools
  if context.tools then
    body.tools = convert_tools(context.tools)
  end

  -- Tool choice
  if options.tool_choice then
    if type(options.tool_choice) == "string" then
      body.tool_choice = { type = options.tool_choice }
    else
      body.tool_choice = options.tool_choice
    end
  end

  -- Thinking configuration
  if model.reasoning then
    if options.thinking_enabled then
      if supports_adaptive(model.id) then
        body.thinking = { type = "adaptive" }
        if options.effort then
          body.output_config = { effort = options.effort }
        end
      else
        body.thinking = {
          type = "enabled",
          budget_tokens = options.thinking_budget_tokens or 1024,
        }
      end
    elseif options.thinking_enabled == false then
      body.thinking = { type = "disabled" }
    end
  end

  return body
end

local function build_headers(model, api_key, options)
  local h = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
  }

  -- Beta features
  local betas = {}
  if not supports_adaptive(model.id) then
    table.insert(betas, "interleaved-thinking-2025-05-14")
  end

  -- Auth style depends on provider
  if model.provider == "github-copilot" then
    h["Authorization"] = "Bearer " .. api_key
    h["accept"] = "application/json"
    h["anthropic-dangerous-direct-browser-access"] = "true"
  else
    h["x-api-key"] = api_key
    h["accept"] = "application/json"
    table.insert(betas, "fine-grained-tool-streaming-2025-05-14")
  end

  if #betas > 0 then
    h["anthropic-beta"] = table.concat(betas, ",")
  end

  -- Model-level headers (e.g. Copilot static headers)
  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end
  if options and options.headers then for k, v in pairs(options.headers) do h[k] = v end end
  return h
end

---------------------------------------------------------------------------
-- API-key resolution
---------------------------------------------------------------------------

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

---------------------------------------------------------------------------
-- Core stream
---------------------------------------------------------------------------

--- Stream a request through the Anthropic Messages API.
---
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
    local endpoint = base_url .. "/v1/messages"
    local headers  = build_headers(model, api_key, options)
    local body     = build_body(model, context, options)

    local output = types.new_assistant_message(model)

    -- Block tracking by Anthropic index
    local blocks_by_index = {} -- [anthropic_index] = { block, our_index }

    es:push({ type = "start", partial = output })

    local error_chunks = {}
    local got_sse = false

    local job_id = curl_stream.stream({
      url = endpoint,
      headers = headers,
      body = body,

      on_event = function(event_type, data)
          if es:is_done() then return end

          got_sse = true
          local ok, evt = pcall(vim.json.decode, data)
          if not ok then table.insert(error_chunks, data); return end

          -- Error response
          if evt.error then
            output.stop_reason = "error"
            output.error_message = evt.error.message or vim.json.encode(evt.error)
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end

          local etype = evt.type or event_type

          if etype == "message_start" and evt.message then
            output.response_id = evt.message.id
            local u = evt.message.usage or {}
            output.usage.input      = u.input_tokens or 0
            output.usage.output     = u.output_tokens or 0
            output.usage.cache_read = u.cache_read_input_tokens or 0
            output.usage.cache_write = u.cache_creation_input_tokens or 0
            output.usage.total_tokens = output.usage.input + output.usage.output
              + output.usage.cache_read + output.usage.cache_write
            types.calculate_cost(model, output.usage)

          elseif etype == "content_block_start" then
            local idx = evt.index
            local cb  = evt.content_block or {}
            if cb.type == "text" then
              local block = { type = "text", text = "" }
              table.insert(output.content, block)
              blocks_by_index[idx] = { block = block, our_index = #output.content }
              es:push({ type = "text_start", content_index = #output.content, partial = output })
            elseif cb.type == "thinking" then
              local block = { type = "thinking", thinking = "", thinking_signature = "" }
              table.insert(output.content, block)
              blocks_by_index[idx] = { block = block, our_index = #output.content }
              es:push({ type = "thinking_start", content_index = #output.content, partial = output })
            elseif cb.type == "redacted_thinking" then
              local block = {
                type = "thinking", thinking = "[Reasoning redacted]",
                thinking_signature = cb.data, redacted = true,
              }
              table.insert(output.content, block)
              blocks_by_index[idx] = { block = block, our_index = #output.content }
              es:push({ type = "thinking_start", content_index = #output.content, partial = output })
            elseif cb.type == "tool_use" then
              local block = {
                type = "toolCall", id = cb.id or "",
                name = cb.name or "", arguments = cb.input or {},
                _partial_json = "",
              }
              table.insert(output.content, block)
              blocks_by_index[idx] = { block = block, our_index = #output.content }
              es:push({ type = "toolcall_start", content_index = #output.content, partial = output })
            end

          elseif etype == "content_block_delta" then
            local info = blocks_by_index[evt.index]
            if not info then return end
            local block, ci = info.block, info.our_index
            local d = evt.delta or {}

            if d.type == "text_delta" and block.type == "text" then
              block.text = block.text .. d.text
              es:push({ type = "text_delta", content_index = ci, delta = d.text, partial = output })
            elseif d.type == "thinking_delta" and block.type == "thinking" then
              block.thinking = block.thinking .. d.thinking
              es:push({ type = "thinking_delta", content_index = ci, delta = d.thinking, partial = output })
            elseif d.type == "input_json_delta" and block.type == "toolCall" then
              block._partial_json = (block._partial_json or "") .. d.partial_json
              local pok, parsed = pcall(vim.json.decode, block._partial_json)
              if pok then block.arguments = parsed end
              es:push({ type = "toolcall_delta", content_index = ci, delta = d.partial_json, partial = output })
            elseif d.type == "signature_delta" and block.type == "thinking" then
              block.thinking_signature = (block.thinking_signature or "") .. d.signature
            end

          elseif etype == "content_block_stop" then
            local info = blocks_by_index[evt.index]
            if not info then return end
            local block, ci = info.block, info.our_index
            if block.type == "text" then
              es:push({ type = "text_end", content_index = ci, content = block.text, partial = output })
            elseif block.type == "thinking" then
              es:push({ type = "thinking_end", content_index = ci, content = block.thinking, partial = output })
            elseif block.type == "toolCall" then
              local pok, parsed = pcall(vim.json.decode, block._partial_json or "{}")
              if pok then block.arguments = parsed end
              block._partial_json = nil
              es:push({ type = "toolcall_end", content_index = ci, tool_call = block, partial = output })
            end

          elseif etype == "message_delta" then
            local d = evt.delta or {}
            if d.stop_reason then
              output.stop_reason = map_stop_reason(d.stop_reason)
            end
            local u = evt.usage or {}
            if u.input_tokens then output.usage.input      = u.input_tokens end
            if u.output_tokens then output.usage.output     = u.output_tokens end
            if u.cache_read_input_tokens then output.usage.cache_read  = u.cache_read_input_tokens end
            if u.cache_creation_input_tokens then output.usage.cache_write = u.cache_creation_input_tokens end
            output.usage.total_tokens = output.usage.input + output.usage.output
              + output.usage.cache_read + output.usage.cache_write
            types.calculate_cost(model, output.usage)

          elseif etype == "message_stop" then
            if output.stop_reason ~= "error" and output.stop_reason ~= "aborted" then
              es:push({ type = "done", reason = output.stop_reason, message = output })
            end
            es:finish()
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
          output.error_message = (eok and edata and edata.error and edata.error.message)
            or raw
          es:push({ type = "error", reason = "error", error = output })
          es:finish()
          return
        end
        if not es:is_done() then
          es:push({ type = "done", reason = output.stop_reason, message = output })
          es:finish()
        end
      end,
    })
      es:set_job_id(job_id)
    end

    if model.provider == "github-copilot" then
      local provider_cfg = require("ai-provider.config").get_provider_config(model.provider) or {}
      local token_override = (options and options.api_key) or provider_cfg.api_key or env_keys.get(model.provider)
      require("ai-provider.providers.copilot").get_token(function(token, base_url, err)
        if token then
          start_request(token, base_url)
        else
          auth_error(err)
        end
      end, token_override)
      return
    end

    local api_key = resolve_api_key(model, options)
    if not api_key then
      auth_error()
      return
    end
    start_request(api_key, model.base_url)
  end)

  return es
end

---------------------------------------------------------------------------
-- stream_simple – unified reasoning interface
---------------------------------------------------------------------------

--- Stream with simplified reasoning option.
---@param model table
---@param context table
---@param options? table  { reasoning?: ThinkingLevel, ... }
---@return EventStream
function M.stream_simple(model, context, options)
  options = options or {}
  local base = {
    api_key     = options.api_key,
    temperature = options.temperature,
    max_tokens  = options.max_tokens or math.min(model.max_tokens or 32000, 32000),
    headers     = options.headers,
    tool_choice = options.tool_choice,
  }

  if not options.reasoning then
    base.thinking_enabled = false
    return M.stream(model, context, base)
  end

  -- Adaptive thinking (Opus 4.6, Sonnet 4.6)
  if supports_adaptive(model.id) then
    base.thinking_enabled = true
    base.effort = map_thinking_level_to_effort(options.reasoning, model.id)
    return M.stream(model, context, base)
  end

  -- Budget-based thinking
  local max_tok, budget = types.adjust_max_tokens_for_thinking(
    base.max_tokens, model.max_tokens or 64000, options.reasoning, options.thinking_budgets
  )
  base.max_tokens = max_tok
  base.thinking_enabled = true
  base.thinking_budget_tokens = budget
  return M.stream(model, context, base)
end

return M
