--- OpenAI Chat Completions streaming provider.
---
--- Covers: OpenAI, OpenRouter, GitHub Copilot (GPT/Gemini models),
---          xAI, Groq, Cerebras, Mistral (fallback), DeepSeek,
---          z.ai, Qwen, and any OpenAI-compatible endpoint.
---
--- Mirrors pi-mono packages/ai/src/providers/openai-completions.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"
local utils        = require "ai-provider.utils"
local transform    = utils.transform
local json_utils   = utils.json
local sanitize     = utils.sanitize

---------------------------------------------------------------------------
-- Compat detection (full port of pi-mono detectCompat/getCompat)
---------------------------------------------------------------------------

local function detect_compat(model)
  local provider = model.provider or ""
  local base_url = model.base_url or ""

  local is_zai = provider == "zai" or base_url:find("api%.z%.ai")
  local is_non_standard =
    provider == "cerebras" or base_url:find("cerebras%.ai")
    or provider == "xai" or base_url:find("api%.x%.ai")
    or base_url:find("chutes%.ai")
    or base_url:find("deepseek%.com")
    or is_zai
    or provider == "opencode" or base_url:find("opencode%.ai")
  local use_max_tokens = base_url:find("chutes%.ai") ~= nil
  local is_grok = provider == "xai" or base_url:find("api%.x%.ai")
  local is_groq = provider == "groq" or base_url:find("groq%.com")

  local cache_control_format = nil
  if provider == "openrouter" and model.id:sub(1, 10) == "anthropic/" then
    cache_control_format = "anthropic"
  end

  local reasoning_effort_map = {}
  if is_groq and model.id == "qwen/qwen3-32b" then
    reasoning_effort_map = {
      minimal = "default", low = "default", medium = "default",
      high = "default", xhigh = "default",
    }
  end

  local thinking_format
  if is_zai then thinking_format = "zai"
  elseif provider == "openrouter" or base_url:find("openrouter%.ai") then thinking_format = "openrouter"
  else thinking_format = "openai" end

  return {
    supports_store              = not is_non_standard,
    supports_developer_role     = not is_non_standard,
    supports_reasoning_effort   = not is_grok and not is_zai,
    reasoning_effort_map        = reasoning_effort_map,
    supports_usage_in_streaming = true,
    max_tokens_field            = use_max_tokens and "max_tokens" or "max_completion_tokens",
    requires_tool_result_name   = false,
    requires_assistant_after_tool_result = false,
    requires_thinking_as_text   = false,
    thinking_format             = thinking_format,
    open_router_routing         = {},
    vercel_gateway_routing      = {},
    zai_tool_stream             = false,
    supports_strict_mode        = true,
    cache_control_format        = cache_control_format,
    send_session_affinity_headers = false,
  }
end

local function get_compat(model)
  local detected = detect_compat(model)
  if not model.compat then return detected end
  local out = {}
  for k, v in pairs(detected) do out[k] = v end
  for k, v in pairs(model.compat) do
    -- model.compat may use either snake_case or detect-order keys; we
    -- already emit snake_case from scripts/generate-models.mjs, so this
    -- just shallow-merges anything the caller set.
    out[k] = v
  end
  return out
end

---------------------------------------------------------------------------
-- Cache-retention helpers
---------------------------------------------------------------------------

local function resolve_cache_retention(retention)
  if retention then return retention end
  if os.getenv("PI_CACHE_RETENTION") == "long" then return "long" end
  return "short"
end

local function get_cache_control(model, compat, cache_retention)
  if compat.cache_control_format ~= "anthropic" or cache_retention == "none" then return nil end
  local cc = { type = "ephemeral" }
  if cache_retention == "long" and (model.base_url or ""):find("api%.anthropic%.com") then
    cc.ttl = "1h"
  end
  return cc
end

local function add_cache_control_to_text_content(msg, cache_control)
  local content = msg.content
  if type(content) == "string" then
    if #content == 0 then return false end
    msg.content = { { type = "text", text = content, cache_control = cache_control } }
    return true
  end
  if type(content) == "table" then
    for i = #content, 1, -1 do
      local p = content[i]
      if p and p.type == "text" then
        p.cache_control = cache_control
        return true
      end
    end
  end
  return false
end

local function apply_anthropic_cache_control(messages, tools, cache_control)
  -- System/developer prompt.
  for _, m in ipairs(messages) do
    if m.role == "system" or m.role == "developer" then
      add_cache_control_to_text_content(m, cache_control)
      break
    end
  end
  -- Last tool.
  if tools and #tools > 0 then
    tools[#tools].cache_control = cache_control
  end
  -- Last user/assistant with a text part.
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m.role == "user" or m.role == "assistant" then
      if add_cache_control_to_text_content(m, cache_control) then break end
    end
  end
end

---------------------------------------------------------------------------
-- Stop-reason / usage parsing
---------------------------------------------------------------------------

local function map_stop_reason(reason)
  if reason == nil or reason == vim.NIL then return "stop" end
  if reason == "stop" or reason == "end" then return "stop" end
  if reason == "length" then return "length" end
  if reason == "function_call" or reason == "tool_calls" then return "toolUse" end
  if reason == "content_filter" then return "error", "Provider finish_reason: content_filter" end
  if reason == "network_error" then return "error", "Provider finish_reason: network_error" end
  return "error", "Provider finish_reason: " .. tostring(reason)
end

local function parse_usage(raw, model)
  local prompt_tokens = raw.prompt_tokens or 0
  local reported_cached = (raw.prompt_tokens_details and raw.prompt_tokens_details.cached_tokens) or 0
  local cache_write = (raw.prompt_tokens_details and raw.prompt_tokens_details.cache_write_tokens) or 0
  local reasoning = (raw.completion_tokens_details and raw.completion_tokens_details.reasoning_tokens) or 0

  local cache_read = cache_write > 0 and math.max(0, reported_cached - cache_write) or reported_cached
  local input = math.max(0, prompt_tokens - cache_read - cache_write)
  local output = (raw.completion_tokens or 0) + reasoning

  local usage = {
    input = input,
    output = output,
    reasoning_tokens = reasoning,
    cache_read = cache_read,
    cache_write = cache_write,
    total_tokens = input + output + cache_read + cache_write,
    cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
  }
  types.calculate_cost(model, usage)
  return usage
end

---------------------------------------------------------------------------
-- Message conversion (uses transform_messages for cross-provider sanity)
---------------------------------------------------------------------------

local function normalize_tool_call_id(model, id)
  if id:find("|", 1, true) then
    local call = id:sub(1, id:find("|", 1, true) - 1)
    return (call:gsub("[^a-zA-Z0-9_%-]", "_")):sub(1, 40)
  end
  if model.provider == "openai" and #id > 40 then return id:sub(1, 40) end
  return id
end

local function is_text_block(b) return b.type == "text" end
local function is_thinking_block(b) return b.type == "thinking" end
local function is_toolcall_block(b) return b.type == "toolCall" end
local function is_image_block(b) return b.type == "image" end

local function has_tool_history(messages)
  for _, m in ipairs(messages) do
    if m.role == "toolResult" then return true end
    if m.role == "assistant" then
      for _, b in ipairs(m.content or {}) do
        if b.type == "toolCall" then return true end
      end
    end
  end
  return false
end

local function convert_messages(model, context, compat)
  local params = {}
  local transformed = transform.transform(context.messages, model, function(id)
    return normalize_tool_call_id(model, id)
  end)

  if context.system_prompt then
    local role = (model.reasoning and compat.supports_developer_role) and "developer" or "system"
    table.insert(params, { role = role, content = sanitize.sanitize_surrogates(context.system_prompt) })
  end

  local last_role = nil
  local i = 1
  while i <= #transformed do
    local msg = transformed[i]

    -- Some providers (Anthropic via LiteLLM etc.) require an assistant
    -- between a toolResult and the next user message.
    if compat.requires_assistant_after_tool_result
        and last_role == "toolResult" and msg.role == "user" then
      table.insert(params, { role = "assistant", content = "I have processed the tool results." })
    end

    if msg.role == "user" then
      if type(msg.content) == "string" then
        table.insert(params, { role = "user", content = sanitize.sanitize_surrogates(msg.content) })
      else
        local parts = {}
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(parts, { type = "text", text = sanitize.sanitize_surrogates(item.text) })
          elseif item.type == "image" then
            table.insert(parts, {
              type = "image_url",
              image_url = { url = "data:" .. item.mime_type .. ";base64," .. item.data },
            })
          end
        end
        if #parts > 0 then
          table.insert(params, { role = "user", content = parts })
        end
      end
      last_role = "user"

    elseif msg.role == "assistant" then
      local amsg = { role = "assistant",
                     content = compat.requires_assistant_after_tool_result and "" or vim.NIL }

      local text_parts, text_all = {}, {}
      for _, b in ipairs(msg.content or {}) do
        if is_text_block(b) and (b.text or ""):match("%S") then
          local t = sanitize.sanitize_surrogates(b.text)
          table.insert(text_parts, { type = "text", text = t })
          table.insert(text_all, t)
        end
      end
      local text_concat = table.concat(text_all, "")

      local thinking_blocks = {}
      for _, b in ipairs(msg.content or {}) do
        if is_thinking_block(b) and (b.thinking or ""):match("%S") then
          table.insert(thinking_blocks, b)
        end
      end

      if #thinking_blocks > 0 then
        if compat.requires_thinking_as_text then
          local all_thinking = {}
          for _, tb in ipairs(thinking_blocks) do table.insert(all_thinking, sanitize.sanitize_surrogates(tb.thinking)) end
          local parts = { { type = "text", text = table.concat(all_thinking, "\n\n") } }
          for _, p in ipairs(text_parts) do table.insert(parts, p) end
          amsg.content = parts
        else
          if #text_concat > 0 then amsg.content = text_concat end
          local sig = thinking_blocks[1].thinking_signature
          if sig and #sig > 0 then
            local joined = {}
            for _, tb in ipairs(thinking_blocks) do table.insert(joined, tb.thinking) end
            amsg[sig] = table.concat(joined, "\n")
          end
        end
      elseif #text_concat > 0 then
        amsg.content = text_concat
      end

      local tool_calls = {}
      for _, b in ipairs(msg.content or {}) do
        if is_toolcall_block(b) then
          table.insert(tool_calls, {
            id = b.id,
            type = "function",
            ["function"] = {
              name = b.name,
              arguments = json_utils.encode_object(b.arguments or {}),
            },
          })
        end
      end
      if #tool_calls > 0 then
        amsg.tool_calls = tool_calls
        -- Propagate reasoning_details when tool calls carry one.
        local rd = {}
        for _, b in ipairs(msg.content or {}) do
          if is_toolcall_block(b) and b.thought_signature then
            local ok, detail = pcall(vim.json.decode, b.thought_signature)
            if ok then table.insert(rd, detail) end
          end
        end
        if #rd > 0 then amsg.reasoning_details = rd end
      end

      local has_content = amsg.content and amsg.content ~= vim.NIL
          and ((type(amsg.content) == "string" and #amsg.content > 0)
               or (type(amsg.content) == "table" and #amsg.content > 0))
      if has_content or amsg.tool_calls then
        -- Strip vim.NIL placeholder when we actually have no content.
        if amsg.content == vim.NIL then amsg.content = nil end
        table.insert(params, amsg)
      end
      last_role = "assistant"

    elseif msg.role == "toolResult" then
      local image_blocks = {}
      local j = i
      local img_support = false
      for _, k in ipairs(model.input or {}) do if k == "image" then img_support = true end end

      while j <= #transformed and transformed[j].role == "toolResult" do
        local tool_msg = transformed[j]
        local text_parts2 = {}
        local has_img = false
        for _, c in ipairs(tool_msg.content or {}) do
          if c.type == "text" then table.insert(text_parts2, c.text)
          elseif c.type == "image" then has_img = true end
        end
        local text_result = table.concat(text_parts2, "\n")
        local has_text = #text_result > 0
        local tr = {
          role = "tool",
          content = sanitize.sanitize_surrogates(has_text and text_result or "(see attached image)"),
          tool_call_id = tool_msg.tool_call_id,
        }
        if compat.requires_tool_result_name and tool_msg.tool_name then
          tr.name = tool_msg.tool_name
        end
        table.insert(params, tr)

        if has_img and img_support then
          for _, b in ipairs(tool_msg.content) do
            if is_image_block(b) then
              table.insert(image_blocks, {
                type = "image_url",
                image_url = { url = "data:" .. b.mime_type .. ";base64," .. b.data },
              })
            end
          end
        end
        j = j + 1
      end
      i = j - 1

      if #image_blocks > 0 then
        if compat.requires_assistant_after_tool_result then
          table.insert(params, { role = "assistant", content = "I have processed the tool results." })
        end
        local user_parts = { { type = "text", text = "Attached image(s) from tool result:" } }
        for _, ib in ipairs(image_blocks) do table.insert(user_parts, ib) end
        table.insert(params, { role = "user", content = user_parts })
        last_role = "user"
      else
        last_role = "toolResult"
      end
    end
    i = i + 1
  end
  return params
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

local function convert_tools(tools, compat)
  local out = {}
  for _, tool in ipairs(tools or {}) do
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
-- Build body
---------------------------------------------------------------------------

local function build_body(model, context, options, compat)
  options = options or {}
  local cache_retention = resolve_cache_retention(options.cache_retention)
  local messages = convert_messages(model, context, compat)
  local cache_control = get_cache_control(model, compat, cache_retention)

  local body = {
    model = model.id,
    messages = messages,
    stream = true,
  }

  if (model.base_url or ""):find("api%.openai%.com") then
    if cache_retention ~= "none" and options.session_id then
      body.prompt_cache_key = options.session_id
    end
    if cache_retention == "long" then
      body.prompt_cache_retention = "24h"
    end
  end

  if compat.supports_usage_in_streaming ~= false then
    body.stream_options = { include_usage = true }
  end
  if compat.supports_store then body.store = false end

  if options.max_tokens then
    if compat.max_tokens_field == "max_tokens" then
      body.max_tokens = options.max_tokens
    else
      body.max_completion_tokens = options.max_tokens
    end
  end
  if options.temperature ~= nil then body.temperature = options.temperature end

  if context.tools and #context.tools > 0 then
    body.tools = convert_tools(context.tools, compat)
    if compat.zai_tool_stream then body.tool_stream = true end
  elseif has_tool_history(context.messages) then
    body.tools = {}
  end

  if cache_control then
    apply_anthropic_cache_control(messages, body.tools, cache_control)
  end

  if options.tool_choice then body.tool_choice = options.tool_choice end

  -- Reasoning
  if model.reasoning then
    if options.reasoning_effort then
      local effort = options.reasoning_effort
      if compat.reasoning_effort_map and compat.reasoning_effort_map[effort] then
        effort = compat.reasoning_effort_map[effort]
      end
      if compat.thinking_format == "openrouter" then
        body.reasoning = { effort = effort }
      elseif compat.thinking_format == "zai" then
        body.enable_thinking = true
      elseif compat.thinking_format == "qwen" then
        body.enable_thinking = true
      elseif compat.thinking_format == "qwen-chat-template" then
        body.chat_template_kwargs = { enable_thinking = true, preserve_thinking = true }
      elseif compat.supports_reasoning_effort then
        body.reasoning_effort = effort
      end
    else
      -- Explicitly disable reasoning formats that require it.
      if compat.thinking_format == "openrouter" then
        body.reasoning = { effort = "none" }
      elseif compat.thinking_format == "zai" then
        body.enable_thinking = false
      elseif compat.thinking_format == "qwen" then
        body.enable_thinking = false
      elseif compat.thinking_format == "qwen-chat-template" then
        body.chat_template_kwargs = { enable_thinking = false, preserve_thinking = true }
      end
    end
  end

  -- OpenRouter routing
  if (model.base_url or ""):find("openrouter%.ai") then
    local routing = model.compat and model.compat.open_router_routing
    if routing and next(routing) then body.provider = routing end
  end
  -- Vercel AI Gateway routing
  if (model.base_url or ""):find("ai%-gateway%.vercel%.sh") then
    local routing = model.compat and model.compat.vercel_gateway_routing
    if routing and (routing.only or routing.order) then
      local gw = {}
      if routing.only then gw.only = routing.only end
      if routing.order then gw.order = routing.order end
      body.providerOptions = { gateway = gw }
    end
  end

  -- User-supplied payload hook
  if options.on_payload then
    local nb = options.on_payload(body, model)
    if nb ~= nil then body = nb end
  end
  return body
end

---------------------------------------------------------------------------
-- Headers
---------------------------------------------------------------------------

local function build_headers(model, context, api_key, options, compat)
  local h = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. api_key,
    ["Accept"] = "text/event-stream",
  }
  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end

  if model.provider == "github-copilot" then
    local copilot = require "ai-provider.providers.copilot"
    local copilot_headers = copilot.build_dynamic_headers(context.messages)
    for k, v in pairs(copilot_headers) do h[k] = v end
  end

  local cache_retention = resolve_cache_retention(options and options.cache_retention)
  local session_id = (cache_retention ~= "none") and options and options.session_id or nil
  if session_id and compat.send_session_affinity_headers then
    h.session_id = session_id
    h["x-client-request-id"] = session_id
    h["x-session-affinity"] = session_id
  end

  if options and options.headers then
    for k, v in pairs(options.headers) do h[k] = v end
  end
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
      local headers  = build_headers(model, context, api_key, options, compat)
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
          current_block.arguments = json_utils.parse_streaming_json(current_block._partial_args or "{}")
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
            else
              es:push({ type = "error", reason = output.stop_reason, error = output })
            end
            es:finish()
            return
          end

          got_sse = true
          local ok, chunk = pcall(vim.json.decode, data)
          if not ok then table.insert(error_chunks, data); return end

          if chunk.error then
            output.stop_reason = "error"
            output.error_message = chunk.error.message or vim.json.encode(chunk.error)
            es:push({ type = "error", reason = "error", error = output })
            es:finish()
            return
          end

          if chunk.usage and chunk.usage ~= vim.NIL then
            output.usage = parse_usage(chunk.usage, model)
          end
          output.response_id = output.response_id or chunk.id

          local choice = chunk.choices and chunk.choices[1]
          if not choice then return end

          -- Some providers put usage inside choice.
          if (not chunk.usage or chunk.usage == vim.NIL) and choice.usage and choice.usage ~= vim.NIL then
            output.usage = parse_usage(choice.usage, model)
          end

          if choice.finish_reason and choice.finish_reason ~= vim.NIL then
            local reason, emsg = map_stop_reason(choice.finish_reason)
            output.stop_reason = reason
            if emsg then output.error_message = emsg end
          end

          local delta = choice.delta
          if not delta then return end

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

          -- Reasoning across possible fields (pick the first non-empty).
          local rfield, rdelta
          for _, field in ipairs({ "reasoning_content", "reasoning", "reasoning_text" }) do
            local v = delta[field]
            if v and v ~= vim.NIL and #tostring(v) > 0 then
              rfield, rdelta = field, v
              break
            end
          end
          if rdelta then
            if not current_block or current_block.type ~= "thinking" then
              finish_block()
              current_block = { type = "thinking", thinking = "", thinking_signature = rfield }
              table.insert(output.content, current_block)
              es:push({ type = "thinking_start", content_index = bidx(), partial = output })
            end
            current_block.thinking = current_block.thinking .. rdelta
            es:push({ type = "thinking_delta", content_index = bidx(), delta = rdelta, partial = output })
          end

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
                current_block.arguments = json_utils.parse_streaming_json(current_block._partial_args)
              end
              es:push({ type = "toolcall_delta", content_index = bidx(), delta = tcd, partial = output })
            end
          end

          -- reasoning_details (OpenRouter-style) → attach to matching toolCall.
          if delta.reasoning_details and type(delta.reasoning_details) == "table" then
            for _, detail in ipairs(delta.reasoning_details) do
              if detail.type == "reasoning.encrypted" and detail.id and detail.data then
                for _, blk in ipairs(output.content) do
                  if blk.type == "toolCall" and blk.id == detail.id then
                    blk.thought_signature = vim.json.encode(detail)
                    break
                  end
                end
              end
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
            output.error_message = (eok and edata and edata.error and edata.error.message) or raw
            es:push({ type = "error", reason = "error", error = output })
            es:finish(); return
          end
          finish_block(); current_block = nil
          if not es:is_done() then
            if output.stop_reason == "error" or output.stop_reason == "aborted" then
              es:push({ type = "error", reason = output.stop_reason, error = output })
            else
              es:push({ type = "done", reason = output.stop_reason, message = output })
            end
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
        if token then start_request(token, base_url) else auth_error(err) end
      end, token_override)
      return
    end

    local api_key = resolve_api_key(model, options)
    if not api_key then auth_error(); return end
    start_request(api_key, model.base_url)
  end)

  return es
end

---------------------------------------------------------------------------
-- stream_simple
---------------------------------------------------------------------------

function M.stream_simple(model, context, options)
  options = options or {}
  local base = {
    api_key         = options.api_key,
    temperature     = options.temperature,
    max_tokens      = options.max_tokens or (model.max_tokens and math.min(model.max_tokens, 32000) or nil),
    headers         = options.headers,
    tool_choice     = options.tool_choice,
    cache_retention = options.cache_retention,
    session_id      = options.session_id,
    on_payload      = options.on_payload,
    on_response     = options.on_response,
    metadata        = options.metadata,
  }
  if options.reasoning and model.reasoning then
    base.reasoning_effort = types.supports_xhigh(model) and options.reasoning or types.clamp_reasoning(options.reasoning)
  end
  return M.stream(model, context, base)
end

return M
