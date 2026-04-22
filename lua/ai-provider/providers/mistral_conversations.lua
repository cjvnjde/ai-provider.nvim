--- Mistral conversations streaming provider.
---
--- Calls Mistral's `/v1/chat/completions` endpoint (`stream=true`). Wire
--- format is OpenAI-ish chat-completions with some extensions:
---   * `delta.content` may be an array of `{type:"text"|"thinking", ...}` chunks.
---   * Tool-call IDs are constrained to 9 alphanumeric characters.
---   * Reasoning models use top-level `prompt_mode:"reasoning"` or
---     `reasoning_effort:"high"` (mistral-small-2603/latest).
---   * Prefix-cache sessions are propagated via an `x-affinity` header.
---
--- Mirrors pi-mono packages/ai/src/providers/mistral.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"
local utils        = require "ai-provider.utils"
local transform    = utils.transform
local hash         = utils.hash
local json_utils   = utils.json
local sanitize     = utils.sanitize

local MISTRAL_TOOL_CALL_ID_LENGTH = 9

---------------------------------------------------------------------------
-- Tool-call ID normalisation
---------------------------------------------------------------------------

local function derive_id(id, attempt)
  local normalized = (id or ""):gsub("[^a-zA-Z0-9]", "")
  if attempt == 0 and #normalized == MISTRAL_TOOL_CALL_ID_LENGTH then return normalized end
  local seed_base = (normalized ~= "") and normalized or id
  local seed = attempt == 0 and seed_base or (seed_base .. ":" .. attempt)
  local h = hash.short_hash(seed):gsub("[^a-zA-Z0-9]", "")
  return h:sub(1, MISTRAL_TOOL_CALL_ID_LENGTH)
end

local function make_normalizer()
  local forward, reverse = {}, {}
  return function(id)
    if forward[id] then return forward[id] end
    local attempt = 0
    while true do
      local candidate = derive_id(id, attempt)
      local owner = reverse[candidate]
      if not owner or owner == id then
        forward[id] = candidate
        reverse[candidate] = id
        return candidate
      end
      attempt = attempt + 1
    end
  end
end

---------------------------------------------------------------------------
-- Message conversion
---------------------------------------------------------------------------

local function supports_images(model)
  for _, k in ipairs(model.input or {}) do if k == "image" then return true end end
  return false
end

local function build_tool_result_text(text, has_images, img_support, is_error)
  local trimmed = (text or ""):match("^%s*(.-)%s*$")
  local prefix = is_error and "[tool error] " or ""
  if trimmed ~= "" then
    local suffix = (has_images and not img_support) and "\n[tool image omitted: model does not support images]" or ""
    return prefix .. trimmed .. suffix
  end
  if has_images then
    if img_support then
      return is_error and "[tool error] (see attached image)" or "(see attached image)"
    end
    return is_error and "[tool error] (image omitted: model does not support images)"
                     or "(image omitted: model does not support images)"
  end
  return is_error and "[tool error] (no tool output)" or "(no tool output)"
end

local function to_chat_messages(messages, img_support)
  local out = {}
  for _, msg in ipairs(messages) do
    if msg.role == "user" then
      if type(msg.content) == "string" then
        table.insert(out, { role = "user", content = sanitize.sanitize_surrogates(msg.content) })
      else
        local had_images = false
        local parts = {}
        for _, item in ipairs(msg.content) do
          if item.type == "image" then had_images = true end
          if item.type == "text" then
            table.insert(parts, { type = "text", text = sanitize.sanitize_surrogates(item.text) })
          elseif item.type == "image" and img_support then
            table.insert(parts, { type = "image_url", image_url = "data:" .. item.mime_type .. ";base64," .. item.data })
          end
        end
        if #parts > 0 then
          table.insert(out, { role = "user", content = parts })
        elseif had_images and not img_support then
          table.insert(out, { role = "user", content = "(image omitted: model does not support images)" })
        end
      end

    elseif msg.role == "assistant" then
      local content_parts = {}
      local tool_calls = {}
      for _, block in ipairs(msg.content or {}) do
        if block.type == "text" then
          if (block.text or ""):match("%S") then
            table.insert(content_parts, { type = "text", text = sanitize.sanitize_surrogates(block.text) })
          end
        elseif block.type == "thinking" then
          if (block.thinking or ""):match("%S") then
            table.insert(content_parts, {
              type = "thinking",
              thinking = { { type = "text", text = sanitize.sanitize_surrogates(block.thinking) } },
            })
          end
        elseif block.type == "toolCall" then
          table.insert(tool_calls, {
            id = block.id,
            type = "function",
            ["function"] = {
              name = block.name,
              arguments = json_utils.encode_object(block.arguments or {}),
            },
          })
        end
      end
      local m = { role = "assistant" }
      if #content_parts > 0 then m.content = content_parts end
      if #tool_calls > 0 then m.tool_calls = tool_calls end
      if m.content or m.tool_calls then table.insert(out, m) end

    elseif msg.role == "toolResult" then
      local text_parts, images = {}, {}
      for _, c in ipairs(msg.content or {}) do
        if c.type == "text" then table.insert(text_parts, sanitize.sanitize_surrogates(c.text))
        elseif c.type == "image" then table.insert(images, c) end
      end
      local text_result = table.concat(text_parts, "\n")
      local tool_text = build_tool_result_text(text_result, #images > 0, img_support, msg.is_error)
      local content = { { type = "text", text = tool_text } }
      if img_support then
        for _, img in ipairs(images) do
          table.insert(content, { type = "image_url", image_url = "data:" .. img.mime_type .. ";base64," .. img.data })
        end
      end
      table.insert(out, {
        role = "tool",
        tool_call_id = msg.tool_call_id,
        name = msg.tool_name,
        content = content,
      })
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Tool / payload helpers
---------------------------------------------------------------------------

local function convert_tools(tools)
  local out = {}
  for _, tool in ipairs(tools or {}) do
    table.insert(out, {
      type = "function",
      ["function"] = {
        name = tool.name,
        description = tool.description,
        parameters = tool.parameters,
        strict = false,
      },
    })
  end
  return out
end

local function map_tool_choice(choice)
  if not choice then return nil end
  if type(choice) == "string" then return choice end
  if type(choice) == "table" and choice["function"] then
    return { type = "function", ["function"] = { name = choice["function"].name } }
  end
  return nil
end

local function map_stop_reason(reason)
  if reason == nil or reason == vim.NIL then return "stop" end
  if reason == "stop" then return "stop" end
  if reason == "length" or reason == "model_length" then return "length" end
  if reason == "tool_calls" then return "toolUse" end
  if reason == "error" then return "error" end
  return "stop"
end

local function uses_reasoning_effort(model)
  return model.id == "mistral-small-2603" or model.id == "mistral-small-latest"
end

---------------------------------------------------------------------------
-- Request building
---------------------------------------------------------------------------

local function build_headers(model, api_key, options)
  local h = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. api_key,
    ["Accept"] = "text/event-stream",
  }
  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end
  if options and options.headers then for k, v in pairs(options.headers) do h[k] = v end end
  -- x-affinity header for KV-cache reuse (prefix caching).
  if options and options.session_id and not h["x-affinity"] then
    h["x-affinity"] = options.session_id
  end
  return h
end

local function build_body(model, context, options)
  options = options or {}
  local normalize = make_normalizer()
  local transformed = transform.transform(context.messages, model, function(id)
    return normalize(id)
  end)

  local messages = to_chat_messages(transformed, supports_images(model))
  if context.system_prompt then
    table.insert(messages, 1, { role = "system", content = sanitize.sanitize_surrogates(context.system_prompt) })
  end

  local body = {
    model = model.id,
    stream = true,
    messages = messages,
  }
  if context.tools and #context.tools > 0 then body.tools = convert_tools(context.tools) end
  if options.temperature ~= nil then body.temperature = options.temperature end
  if options.max_tokens ~= nil then body.max_tokens = options.max_tokens end
  local tc = map_tool_choice(options.tool_choice)
  if tc then body.tool_choice = tc end
  if options.prompt_mode then body.prompt_mode = options.prompt_mode end
  if options.reasoning_effort then body.reasoning_effort = options.reasoning_effort end
  if options.on_payload then
    local nb = options.on_payload(body, model)
    if nb ~= nil then body = nb end
  end
  return body
end

---------------------------------------------------------------------------
-- Streaming chunk processing
---------------------------------------------------------------------------

local function finish_block(es, output, block)
  if not block then return end
  local ci = #output.content
  if block.type == "text" then
    es:push({ type = "text_end", content_index = ci, content = block.text, partial = output })
  elseif block.type == "thinking" then
    es:push({ type = "thinking_end", content_index = ci, content = block.thinking, partial = output })
  end
end

local function push_text_delta(es, output, state, text)
  if text == "" then return end
  if not state.current or state.current.type ~= "text" then
    finish_block(es, output, state.current)
    state.current = { type = "text", text = "" }
    table.insert(output.content, state.current)
    es:push({ type = "text_start", content_index = #output.content, partial = output })
  end
  state.current.text = state.current.text .. text
  es:push({ type = "text_delta", content_index = #output.content, delta = text, partial = output })
end

local function push_thinking_delta(es, output, state, text)
  if text == "" then return end
  if not state.current or state.current.type ~= "thinking" then
    finish_block(es, output, state.current)
    state.current = { type = "thinking", thinking = "" }
    table.insert(output.content, state.current)
    es:push({ type = "thinking_start", content_index = #output.content, partial = output })
  end
  state.current.thinking = state.current.thinking .. text
  es:push({ type = "thinking_delta", content_index = #output.content, delta = text, partial = output })
end

local function process_chunk(chunk, output, es, state, model)
  -- `chunk` is the inner CompletionChunk (chunk.id, chunk.choices, chunk.usage).
  output.response_id = output.response_id or chunk.id

  if chunk.usage then
    output.usage.input        = chunk.usage.prompt_tokens or 0
    output.usage.output       = chunk.usage.completion_tokens or 0
    output.usage.cache_read   = 0
    output.usage.cache_write  = 0
    output.usage.total_tokens = chunk.usage.total_tokens or (output.usage.input + output.usage.output)
    types.calculate_cost(model, output.usage)
  end

  local choice = chunk.choices and chunk.choices[1]
  if not choice then return end

  if choice.finish_reason and choice.finish_reason ~= vim.NIL then
    output.stop_reason = map_stop_reason(choice.finish_reason)
  end

  local delta = choice.delta
  if not delta then return end

  if delta.content ~= nil and delta.content ~= vim.NIL then
    local items
    if type(delta.content) == "string" then
      items = { delta.content }
    else
      items = delta.content
    end
    for _, item in ipairs(items) do
      if type(item) == "string" then
        push_text_delta(es, output, state, sanitize.sanitize_surrogates(item))
      elseif type(item) == "table" then
        if item.type == "thinking" then
          local text_parts = {}
          for _, p in ipairs(item.thinking or {}) do
            if p.text then table.insert(text_parts, p.text) end
          end
          push_thinking_delta(es, output, state, sanitize.sanitize_surrogates(table.concat(text_parts)))
        elseif item.type == "text" then
          push_text_delta(es, output, state, sanitize.sanitize_surrogates(item.text or ""))
        end
      end
    end
  end

  if delta.tool_calls then
    for _, tc in ipairs(delta.tool_calls) do
      -- Close any open text/thinking block before starting a toolCall.
      if state.current then
        finish_block(es, output, state.current)
        state.current = nil
      end
      local call_id = tc.id
      if not call_id or call_id == vim.NIL or call_id == "null" then
        call_id = derive_id("toolcall:" .. tostring(tc.index or 0), 0)
      end
      local key = call_id .. ":" .. tostring(tc.index or 0)
      state.tool_blocks = state.tool_blocks or {}
      local existing_idx = state.tool_blocks[key]
      local block
      if existing_idx then
        block = output.content[existing_idx]
      end
      if not block or block.type ~= "toolCall" then
        block = {
          type = "toolCall",
          id = call_id,
          name = (tc["function"] and tc["function"].name) or "",
          arguments = {},
          _partial_args = "",
        }
        table.insert(output.content, block)
        state.tool_blocks[key] = #output.content
        es:push({ type = "toolcall_start", content_index = #output.content, partial = output })
      end
      local args_delta = ""
      if tc["function"] and tc["function"].arguments then
        if type(tc["function"].arguments) == "string" then
          args_delta = tc["function"].arguments
        else
          args_delta = json_utils.encode_object(tc["function"].arguments)
        end
      end
      block._partial_args = (block._partial_args or "") .. args_delta
      block.arguments = json_utils.parse_streaming_json(block._partial_args)
      es:push({ type = "toolcall_delta", content_index = state.tool_blocks[key], delta = args_delta, partial = output })
    end
  end
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

function M.stream(model, context, options)
  options = options or {}
  local es = EventStream.new()

  vim.schedule(function()
    local api_key = resolve_api_key(model, options)
    if not api_key then
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = "No API key for provider: " .. model.provider .. ". Set MISTRAL_API_KEY."
      es:push({ type = "error", reason = "error", error = out })
      es:finish(); return
    end

    local base_url = model.base_url
    if base_url:sub(-1) == "/" then base_url = base_url:sub(1, -2) end
    local endpoint = base_url .. "/v1/chat/completions"
    local headers  = build_headers(model, api_key, options)
    local body     = build_body(model, context, options)

    local output = types.new_assistant_message(model)
    local state  = { current = nil, tool_blocks = {} }
    local got_sse, error_chunks = false, {}

    es:push({ type = "start", partial = output })

    local job_id = curl_stream.stream({
      url = endpoint,
      headers = headers,
      body = body,
      on_event = function(_, data)
        if es:is_done() then return end
        if data == "[DONE]" then return end
        got_sse = true
        local ok, chunk = pcall(vim.json.decode, data)
        if not ok then table.insert(error_chunks, data); return end
        if chunk.error then
          output.stop_reason = "error"
          output.error_message = (chunk.error.message or vim.json.encode(chunk.error))
          es:push({ type = "error", reason = "error", error = output })
          es:finish(); return
        end
        process_chunk(chunk, output, es, state, model)
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
        finish_block(es, output, state.current)
        state.current = nil
        -- Finalise tool-call blocks
        for _, idx in pairs(state.tool_blocks or {}) do
          local b = output.content[idx]
          if b and b.type == "toolCall" then
            b.arguments = json_utils.parse_streaming_json(b._partial_args)
            b._partial_args = nil
            es:push({ type = "toolcall_end", content_index = idx, tool_call = b, partial = output })
          end
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
  end)

  return es
end

function M.stream_simple(model, context, options)
  options = options or {}
  local base = {
    api_key     = options.api_key,
    temperature = options.temperature,
    max_tokens  = options.max_tokens or (model.max_tokens and math.min(model.max_tokens, 32000) or nil),
    headers     = options.headers,
    tool_choice = options.tool_choice,
    session_id  = options.session_id,
    on_payload  = options.on_payload,
  }

  local reasoning = types.clamp_reasoning(options.reasoning)
  local should_reason = model.reasoning and reasoning ~= nil
  if should_reason then
    if uses_reasoning_effort(model) then
      base.reasoning_effort = "high"
    else
      base.prompt_mode = "reasoning"
    end
  end
  return M.stream(model, context, base)
end

return M
