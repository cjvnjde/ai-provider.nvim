--- Google Generative AI (Gemini) streaming provider.
---
--- Covers: Gemini models via the Google AI Studio / Generative Language API.
--- Supports thinking (budget-based for 2.5, level-based for 3.x).
---
--- Mirrors pi-mono packages/ai/src/providers/google.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"

---------------------------------------------------------------------------
-- Stop-reason mapping
---------------------------------------------------------------------------

local function map_stop_reason(reason)
  if reason == "STOP" then return "stop" end
  if reason == "MAX_TOKENS" then return "length" end
  if reason == "SAFETY" or reason == "RECITATION" then return "error" end
  if reason == "OTHER" then return "error" end
  return "stop"
end

---------------------------------------------------------------------------
-- Message conversion
---------------------------------------------------------------------------

local function convert_messages(model, context)
  local contents = {}

  for _, msg in ipairs(context.messages) do
    if msg.role == "user" then
      local parts = {}
      if type(msg.content) == "string" then
        table.insert(parts, { text = msg.content })
      else
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(parts, { text = item.text })
          elseif item.type == "image" then
            table.insert(parts, {
              inlineData = { mimeType = item.mime_type, data = item.data },
            })
          end
        end
      end
      table.insert(contents, { role = "user", parts = parts })

    elseif msg.role == "assistant" then
      local parts = {}
      for _, block in ipairs(msg.content) do
        if block.type == "text" and block.text and #block.text > 0 then
          table.insert(parts, { text = block.text })
        elseif block.type == "thinking" and block.thinking and #block.thinking > 0 then
          table.insert(parts, { text = block.thinking, thought = true })
        elseif block.type == "toolCall" then
          table.insert(parts, {
            functionCall = {
              name = block.name,
              args = block.arguments or {},
            },
          })
        end
      end
      if #parts > 0 then
        table.insert(contents, { role = "model", parts = parts })
      end

    elseif msg.role == "toolResult" then
      local text = ""
      if msg.content then
        for _, c in ipairs(msg.content) do
          if c.type == "text" then text = text .. c.text end
        end
      end
      table.insert(contents, {
        role = "user",
        parts = {
          {
            functionResponse = {
              name = msg.tool_name or "unknown",
              response = { result = text ~= "" and text or "(empty)" },
            },
          },
        },
      })
    end
  end
  return contents
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

local function convert_tools(tools)
  if not tools or #tools == 0 then return nil end
  local decls = {}
  for _, tool in ipairs(tools) do
    table.insert(decls, {
      name = tool.name,
      description = tool.description,
      parameters = tool.parameters,
    })
  end
  return { { functionDeclarations = decls } }
end

---------------------------------------------------------------------------
-- Thinking config helpers
---------------------------------------------------------------------------

local function is_gemini_3_pro(model_id)
  return model_id:lower():find("gemini%-3[%.%d]*%-pro") ~= nil
end

local function is_gemini_3_flash(model_id)
  return model_id:lower():find("gemini%-3[%.%d]*%-flash") ~= nil
end

local function get_thinking_level(effort, model_id)
  if is_gemini_3_pro(model_id) then
    if effort == "minimal" or effort == "low" then return "LOW" end
    return "HIGH"
  end
  if effort == "minimal" then return "MINIMAL" end
  if effort == "low" then return "LOW" end
  if effort == "medium" then return "MEDIUM" end
  return "HIGH"
end

local function get_google_budget(model_id, effort, custom)
  if custom and custom[effort] then return custom[effort] end
  if model_id:find("2%.5%-pro") then
    local b = { minimal = 128, low = 2048, medium = 8192, high = 32768 }
    return b[effort] or 8192
  end
  if model_id:find("2%.5%-flash") then
    local b = { minimal = 128, low = 2048, medium = 8192, high = 24576 }
    return b[effort] or 8192
  end
  return -1 -- dynamic
end

local function get_disabled_thinking(model_id)
  if is_gemini_3_pro(model_id) then
    return { thinkingLevel = "LOW" }
  end
  if is_gemini_3_flash(model_id) then
    return { thinkingLevel = "MINIMAL" }
  end
  return { thinkingBudget = 0 }
end

---------------------------------------------------------------------------
-- Build request
---------------------------------------------------------------------------

local function build_body(model, context, options)
  options = options or {}
  local body = {
    contents = convert_messages(model, context),
  }

  -- System instruction (top-level, not inside generationConfig)
  if context.system_prompt then
    body.systemInstruction = { parts = { { text = context.system_prompt } } }
  end

  -- Tools (top-level)
  if context.tools and #context.tools > 0 then
    body.tools = convert_tools(context.tools)
    if options.tool_choice then
      body.toolConfig = {
        functionCallingConfig = {
          mode = options.tool_choice == "none" and "NONE"
            or options.tool_choice == "any" and "ANY"
            or "AUTO",
        },
      }
    end
  end

  -- Generation config
  local gen_config = {}
  if options.temperature then gen_config.temperature = options.temperature end
  if options.max_tokens then gen_config.maxOutputTokens = options.max_tokens end

  -- Thinking config (nested inside generationConfig)
  if options.thinking and model.reasoning then
    if options.thinking.enabled then
      local tc = { includeThoughts = true }
      if options.thinking.level then
        tc.thinkingLevel = options.thinking.level
      elseif options.thinking.budget_tokens then
        tc.thinkingBudget = options.thinking.budget_tokens
      end
      gen_config.thinkingConfig = tc
    elseif options.thinking.enabled == false then
      gen_config.thinkingConfig = get_disabled_thinking(model.id)
    end
  end

  if next(gen_config) then
    body.generationConfig = gen_config
  end

  return body
end

---------------------------------------------------------------------------
-- API-key resolution
---------------------------------------------------------------------------

local function resolve_api_key(model, options)
  if options and options.api_key then return options.api_key end
  local cfg = require("ai-provider.config").get_provider_config(model.provider)
  if cfg and cfg.api_key then return cfg.api_key end
  return env_keys.get(model.provider)
end

---------------------------------------------------------------------------
-- Core stream
---------------------------------------------------------------------------

--- Stream a request through the Google Generative AI API.
---@param model table
---@param context table
---@param options? table
---@return EventStream
function M.stream(model, context, options)
  options = options or {}
  local es = EventStream.new()

  vim.schedule(function()
    local api_key = resolve_api_key(model, options)
    if not api_key then
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = "No API key for provider: " .. model.provider .. ". Set GEMINI_API_KEY."
      es:push({ type = "error", reason = "error", error = out })
      es:finish()
      return
    end

    local base_url = model.base_url
    if base_url:sub(-1) == "/" then base_url = base_url:sub(1, -2) end
    local endpoint = base_url .. "/models/" .. model.id .. ":streamGenerateContent?key=" .. api_key .. "&alt=sse"

    local headers = { ["Content-Type"] = "application/json" }
    if model.headers then for k, v in pairs(model.headers) do headers[k] = v end end
    if options.headers then for k, v in pairs(options.headers) do headers[k] = v end end

    local body = build_body(model, context, options)

    local output = types.new_assistant_message(model)
    local current_block = nil
    local tool_call_counter = 0
    local got_sse = false
    local error_chunks = {}

    local function bidx() return #output.content end

    local function finish_block()
      if not current_block then return end
      if current_block.type == "text" then
        es:push({ type = "text_end", content_index = bidx(), content = current_block.text, partial = output })
      elseif current_block.type == "thinking" then
        es:push({ type = "thinking_end", content_index = bidx(), content = current_block.thinking, partial = output })
      end
    end

    es:push({ type = "start", partial = output })

    local job_id = curl_stream.stream({
      url = endpoint,
      headers = headers,
      body = body,

      on_event = function(_, data)
        vim.schedule(function()
          if es:is_done() then return end

          got_sse = true
          local ok, chunk = pcall(vim.json.decode, data)
          if not ok then table.insert(error_chunks, data); return end

          -- Error response
          if chunk.error then
            output.stop_reason = "error"
            output.error_message = chunk.error.message or vim.json.encode(chunk.error)
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end

          output.response_id = output.response_id or chunk.responseId

          local candidate = chunk.candidates and chunk.candidates[1]
          if candidate and candidate.content and candidate.content.parts then
            for _, part in ipairs(candidate.content.parts) do
              -- Text or thinking
              if part.text ~= nil then
                local is_thinking = part.thought == true
                if not current_block
                  or (is_thinking and current_block.type ~= "thinking")
                  or (not is_thinking and current_block.type ~= "text") then
                  finish_block()
                  if is_thinking then
                    current_block = { type = "thinking", thinking = "" }
                    table.insert(output.content, current_block)
                    es:push({ type = "thinking_start", content_index = bidx(), partial = output })
                  else
                    current_block = { type = "text", text = "" }
                    table.insert(output.content, current_block)
                    es:push({ type = "text_start", content_index = bidx(), partial = output })
                  end
                end
                if current_block.type == "thinking" then
                  current_block.thinking = current_block.thinking .. part.text
                  es:push({ type = "thinking_delta", content_index = bidx(), delta = part.text, partial = output })
                else
                  current_block.text = current_block.text .. part.text
                  es:push({ type = "text_delta", content_index = bidx(), delta = part.text, partial = output })
                end
              end

              -- Function call
              if part.functionCall then
                finish_block(); current_block = nil
                tool_call_counter = tool_call_counter + 1
                local tc = {
                  type = "toolCall",
                  id = part.functionCall.id or (part.functionCall.name .. "_" .. tool_call_counter),
                  name = part.functionCall.name or "",
                  arguments = part.functionCall.args or {},
                }
                table.insert(output.content, tc)
                es:push({ type = "toolcall_start", content_index = bidx(), partial = output })
                es:push({ type = "toolcall_delta", content_index = bidx(),
                  delta = vim.json.encode(tc.arguments), partial = output })
                es:push({ type = "toolcall_end", content_index = bidx(), tool_call = tc, partial = output })
              end
            end
          end

          -- Finish reason
          if candidate and candidate.finishReason then
            output.stop_reason = map_stop_reason(candidate.finishReason)
            if #vim.tbl_filter(function(b) return b.type == "toolCall" end, output.content) > 0 then
              output.stop_reason = "toolUse"
            end
          end

          -- Usage
          if chunk.usageMetadata then
            local um = chunk.usageMetadata
            output.usage = {
              input        = (um.promptTokenCount or 0) - (um.cachedContentTokenCount or 0),
              output       = (um.candidatesTokenCount or 0) + (um.thoughtsTokenCount or 0),
              cache_read   = um.cachedContentTokenCount or 0,
              cache_write  = 0,
              total_tokens = um.totalTokenCount or 0,
              cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
            }
            types.calculate_cost(model, output.usage)
          end
        end)
      end,

      on_error = function(err)
        if es:is_done() then return end
        output.stop_reason = "error"; output.error_message = err
        es:push({ type = "error", reason = "error", error = output })
        es:finish()
      end,

      on_done = function()
        if es:is_done() then return end
        finish_block(); current_block = nil
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
  end)

  return es
end

---------------------------------------------------------------------------
-- stream_simple
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
    base.thinking = { enabled = false }
    return M.stream(model, context, base)
  end

  local effort = types.clamp_reasoning(options.reasoning) or "high"

  -- Gemini 3.x: level-based
  if is_gemini_3_pro(model.id) or is_gemini_3_flash(model.id) then
    base.thinking = { enabled = true, level = get_thinking_level(effort, model.id) }
    return M.stream(model, context, base)
  end

  -- Gemini 2.5.x: budget-based
  base.thinking = {
    enabled = true,
    budget_tokens = get_google_budget(model.id, effort, options.thinking_budgets),
  }
  return M.stream(model, context, base)
end

return M
