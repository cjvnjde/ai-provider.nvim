--- OpenAI Chat Completions streaming provider.
---
--- Covers: OpenAI, OpenRouter, GitHub Copilot (GPT/Gemini models),
---          xAI, Groq, Cerebras, Mistral, DeepSeek, and any
---          OpenAI-compatible endpoint.
---
--- Mirrors pi-mono packages/ai/src/providers/openai-completions.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"

---------------------------------------------------------------------------
-- Compat detection (like pi-mono's detectCompat / getCompat)
---------------------------------------------------------------------------

local function get_compat(model)
  local defaults = {
    supports_store            = true,
    supports_developer_role   = true,
    supports_reasoning_effort = true,
    reasoning_effort_map      = {},
    supports_usage_in_streaming = true,
    max_tokens_field          = "max_completion_tokens",
    thinking_format           = "openai", -- "openai" | "openrouter" | "zai"
    supports_strict_mode      = true,
  }

  local p   = model.provider or ""
  local url = model.base_url or ""

  if p == "openrouter" or url:find("openrouter%.ai") then
    defaults.thinking_format = "openrouter"
  end

  local non_standard = (p == "cerebras" or p == "xai" or p == "groq"
    or url:find("cerebras%.ai") or url:find("api%.x%.ai")
    or url:find("deepseek%.com") or url:find("chutes%.ai"))
  if non_standard then
    defaults.supports_store = false
    defaults.supports_developer_role = false
  end

  if p == "xai" or url:find("api%.x%.ai") then
    defaults.supports_reasoning_effort = false
  end

  if p == "github-copilot" then
    defaults.supports_store = false
    defaults.supports_developer_role = false
  end

  if url:find("chutes%.ai") then
    defaults.max_tokens_field = "max_tokens"
  end

  -- Apply model-level overrides
  if model.compat then
    for k, v in pairs(model.compat) do defaults[k] = v end
  end
  return defaults
end

---------------------------------------------------------------------------
-- Stop-reason mapping
---------------------------------------------------------------------------

local function map_stop_reason(reason)
  if reason == nil or reason == vim.NIL then return "stop" end
  if reason == "stop" or reason == "end" then return "stop" end
  if reason == "length" then return "length" end
  if reason == "function_call" or reason == "tool_calls" then return "toolUse" end
  if reason == "content_filter" then return "error", "content_filter" end
  return "error", "finish_reason: " .. tostring(reason)
end

---------------------------------------------------------------------------
-- Message conversion
---------------------------------------------------------------------------

local function convert_messages(model, context, compat)
  local params = {}

  if context.system_prompt then
    local role = (model.reasoning and compat.supports_developer_role) and "developer" or "system"
    table.insert(params, { role = role, content = context.system_prompt })
  end

  for _, msg in ipairs(context.messages) do
    if msg.role == "user" then
      if type(msg.content) == "string" then
        table.insert(params, { role = "user", content = msg.content })
      else
        local parts = {}
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(parts, { type = "text", text = item.text })
          elseif item.type == "image" then
            table.insert(parts, {
              type = "image_url",
              image_url = { url = "data:" .. item.mime_type .. ";base64," .. item.data },
            })
          end
        end
        table.insert(params, { role = "user", content = parts })
      end

    elseif msg.role == "assistant" then
      local amsg = { role = "assistant" }
      local texts, tool_calls = {}, {}
      for _, block in ipairs(msg.content) do
        if block.type == "text" and block.text and #block.text > 0 then
          table.insert(texts, block.text)
        elseif block.type == "toolCall" then
          table.insert(tool_calls, {
            id = block.id,
            type = "function",
            ["function"] = {
              name = block.name,
              arguments = vim.json.encode(block.arguments or {}),
            },
          })
        end
      end
      if #texts > 0 then amsg.content = table.concat(texts, "") end
      if #tool_calls > 0 then amsg.tool_calls = tool_calls end
      if amsg.content or amsg.tool_calls then
        table.insert(params, amsg)
      end

    elseif msg.role == "toolResult" then
      local text = ""
      if msg.content then
        for _, c in ipairs(msg.content) do
          if c.type == "text" then text = text .. c.text end
        end
      end
      table.insert(params, {
        role = "tool",
        content = text ~= "" and text or "(empty)",
        tool_call_id = msg.tool_call_id,
      })
    end
  end
  return params
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

local function convert_tools(tools, compat)
  if not tools or #tools == 0 then return nil end
  local out = {}
  for _, tool in ipairs(tools) do
    local fn = {
      name = tool.name,
      description = tool.description,
      parameters = tool.parameters,
    }
    if compat.supports_strict_mode ~= false then fn.strict = false end
    table.insert(out, { type = "function", ["function"] = fn })
  end
  return out
end

---------------------------------------------------------------------------
-- Build request body
---------------------------------------------------------------------------

local function build_body(model, context, options, compat)
  options = options or {}
  local body = {
    model = model.id,
    messages = convert_messages(model, context, compat),
    stream = true,
  }

  if compat.supports_usage_in_streaming ~= false then
    body.stream_options = { include_usage = true }
  end
  if compat.supports_store then body.store = false end

  -- Max tokens
  if options.max_tokens then
    if compat.max_tokens_field == "max_tokens" then
      body.max_tokens = options.max_tokens
    else
      body.max_completion_tokens = options.max_tokens
    end
  end

  if options.temperature then body.temperature = options.temperature end

  -- Tools
  if context.tools then
    body.tools = convert_tools(context.tools, compat)
  end

  -- Tool choice
  if options.tool_choice then body.tool_choice = options.tool_choice end

  -- Reasoning
  if options.reasoning_effort and model.reasoning then
    local effort = options.reasoning_effort
    if compat.reasoning_effort_map and compat.reasoning_effort_map[effort] then
      effort = compat.reasoning_effort_map[effort]
    end
    if compat.thinking_format == "openrouter" then
      body.reasoning = { effort = effort }
    elseif compat.thinking_format == "zai" then
      body.enable_thinking = true
    elseif compat.supports_reasoning_effort then
      body.reasoning_effort = effort
    end
  elseif compat.thinking_format == "openrouter" and model.reasoning and not options.reasoning_effort then
    body.reasoning = { effort = "none" }
  end

  return body
end

---------------------------------------------------------------------------
-- Build headers
---------------------------------------------------------------------------

local function build_headers(model, api_key, options)
  local h = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. api_key,
  }
  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end
  if options and options.headers then for k, v in pairs(options.headers) do h[k] = v end end
  return h
end

---------------------------------------------------------------------------
-- Usage parsing
---------------------------------------------------------------------------

local function parse_usage(raw, model)
  local cached = 0
  if raw.prompt_tokens_details then
    cached = raw.prompt_tokens_details.cached_tokens or 0
  end
  local reasoning = 0
  if raw.completion_tokens_details then
    reasoning = raw.completion_tokens_details.reasoning_tokens or 0
  end
  local input  = (raw.prompt_tokens or 0) - cached
  local output = (raw.completion_tokens or 0) + reasoning
  local usage  = {
    input            = input,
    output           = output,
    reasoning_tokens = reasoning,
    cache_read       = cached,
    cache_write      = 0,
    total_tokens     = input + output + cached,
    cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
  }
  types.calculate_cost(model, usage)
  return usage
end

---------------------------------------------------------------------------
-- Resolve API key (env → credential store for Copilot → config)
---------------------------------------------------------------------------

local function resolve_api_key(model, options)
  if options and options.api_key then return options.api_key end

  -- Provider config
  local cfg = require("ai-provider.config").get_provider_config(model.provider)
  if cfg and cfg.api_key then return cfg.api_key end

  -- Env
  local key = env_keys.get(model.provider)
  if key then return key end

  -- Copilot credential store (session token)
  if model.provider == "github-copilot" then
    local creds = require("ai-provider.credential_store").read("github-copilot")
    if creds and creds.access_token then return creds.access_token end
  end
  return nil
end

---------------------------------------------------------------------------
-- Core stream implementation
---------------------------------------------------------------------------

--- Stream a request through the OpenAI Chat Completions API.
---
---@param model table    Rich model definition
---@param context table  { system_prompt?, messages, tools? }
---@param options? table { api_key?, temperature?, max_tokens?, reasoning_effort?, headers?, tool_choice? }
---@return EventStream
function M.stream(model, context, options)
  options = options or {}
  local es = EventStream.new()

  vim.schedule(function()
    local function auth_error(err)
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = err or ("No API key for provider: " .. model.provider
        .. ". Set " .. (model.provider == "github-copilot"
          and "COPILOT_GITHUB_TOKEN / run :AiLogin github-copilot"
          or (model.provider:upper():gsub("-", "_") .. "_API_KEY")))
      es:push({ type = "error", reason = "error", error = out })
      es:finish()
    end

    local function start_request(api_key, resolved_base_url)
      local compat   = get_compat(model)
      local base_url = resolved_base_url or model.base_url
    if base_url:sub(-1) == "/" then base_url = base_url:sub(1, -2) end
    local endpoint = base_url .. "/chat/completions"
    local headers  = build_headers(model, api_key, options)
    local body     = build_body(model, context, options, compat)

    local output        = types.new_assistant_message(model)
    local current_block = nil
    local got_sse       = false
    local error_chunks  = {}

    local function bidx() return #output.content end

    local function finish_block()
      if not current_block then return end
      if current_block.type == "text" then
        es:push({ type = "text_end", content_index = bidx(), content = current_block.text, partial = output })
      elseif current_block.type == "thinking" then
        es:push({ type = "thinking_end", content_index = bidx(), content = current_block.thinking, partial = output })
      elseif current_block.type == "toolCall" then
        local ok, args = pcall(vim.json.decode, current_block._partial_args or "{}")
        if ok then current_block.arguments = args end
        current_block._partial_args = nil
        es:push({ type = "toolcall_end", content_index = bidx(), tool_call = current_block, partial = output })
      end
    end

    es:push({ type = "start", partial = output })

    local job_id = curl_stream.stream({
      url = endpoint,
      headers = headers,
      body = body,

      on_event = function(_, data)
          if es:is_done() then return end

          if data == "[DONE]" then
            finish_block(); current_block = nil
            if output.stop_reason ~= "error" and output.stop_reason ~= "aborted" then
              es:push({ type = "done", reason = output.stop_reason, message = output })
            end
            es:finish()
            return
          end

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

          if chunk.usage then output.usage = parse_usage(chunk.usage, model) end
          output.response_id = output.response_id or chunk.id

          local choice = chunk.choices and chunk.choices[1]
          if not choice then return end

          if choice.finish_reason and choice.finish_reason ~= vim.NIL then
            local reason, emsg = map_stop_reason(choice.finish_reason)
            output.stop_reason = reason
            if emsg then output.error_message = emsg end
          end

          local delta = choice.delta
          if not delta then return end

          -- Text content
          if delta.content and delta.content ~= vim.NIL and #delta.content > 0 then
            if not current_block or current_block.type ~= "text" then
              finish_block()
              current_block = { type = "text", text = "" }
              table.insert(output.content, current_block)
              es:push({ type = "text_start", content_index = bidx(), partial = output })
            end
            current_block.text = current_block.text .. delta.content
            es:push({ type = "text_delta", content_index = bidx(), delta = delta.content, partial = output })
          end

          -- Reasoning content
          local rdelta = delta.reasoning_content or delta.reasoning or delta.reasoning_text
          if rdelta and rdelta ~= vim.NIL and #tostring(rdelta) > 0 then
            if not current_block or current_block.type ~= "thinking" then
              finish_block()
              current_block = { type = "thinking", thinking = "" }
              table.insert(output.content, current_block)
              es:push({ type = "thinking_start", content_index = bidx(), partial = output })
            end
            current_block.thinking = current_block.thinking .. rdelta
            es:push({ type = "thinking_delta", content_index = bidx(), delta = rdelta, partial = output })
          end

          -- Tool calls
          if delta.tool_calls then
            for _, tc in ipairs(delta.tool_calls) do
              if not current_block or current_block.type ~= "toolCall"
                or (tc.id and current_block.id ~= tc.id) then
                finish_block()
                current_block = {
                  type = "toolCall", id = tc.id or "", name = "",
                  arguments = {}, _partial_args = "",
                }
                if tc["function"] and tc["function"].name then
                  current_block.name = tc["function"].name
                end
                table.insert(output.content, current_block)
                es:push({ type = "toolcall_start", content_index = bidx(), partial = output })
              end
              if tc.id then current_block.id = tc.id end
              if tc["function"] and tc["function"].name then current_block.name = tc["function"].name end
              local tcd = ""
              if tc["function"] and tc["function"].arguments then
                tcd = tc["function"].arguments
                current_block._partial_args = (current_block._partial_args or "") .. tcd
                local pok, parsed = pcall(vim.json.decode, current_block._partial_args)
                if pok then current_block.arguments = parsed end
              end
              es:push({ type = "toolcall_delta", content_index = bidx(), delta = tcd, partial = output })
            end
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
        finish_block(); current_block = nil
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
  local sopts = {
    api_key     = options.api_key,
    temperature = options.temperature,
    max_tokens  = options.max_tokens or math.min(model.max_tokens or 32000, 32000),
    headers     = options.headers,
    tool_choice = options.tool_choice,
  }
  if options.reasoning and model.reasoning then
    sopts.reasoning_effort = types.clamp_reasoning(options.reasoning)
  end
  return M.stream(model, context, sopts)
end

return M
