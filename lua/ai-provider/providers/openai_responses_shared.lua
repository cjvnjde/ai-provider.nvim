--- Shared helpers for OpenAI Responses-style APIs.
---
--- Mirrors pi-mono packages/ai/src/providers/openai-responses-shared.ts.
---
--- Covers:
---   * Message conversion (user / assistant / toolResult → ResponseInput items).
---   * Tool conversion (pi-ai Tool → Responses function tool).
---   * Stream-event processing (response.output_item.added / .delta / .done /
---     response.completed / error).
---
--- The `process_event(evt, state)` function is designed to be driven by the
--- SSE parser in curl_stream.lua — each SSE frame decoded from JSON is passed
--- in along with a mutable `state` table. `state.output` is the
--- AssistantMessage under construction; `state.es` is the EventStream to push
--- pi-ai events to; `state.model` / `state.apply_service_tier_pricing` /
--- `state.service_tier` are looked at on completion.
local M = {}

local utils    = require "ai-provider.utils"
local types    = require "ai-provider.types"
local transform = utils.transform
local hash     = utils.hash
local json     = utils.json
local sanitize = utils.sanitize

---------------------------------------------------------------------------
-- Text signature helpers (TextSignatureV1 JSON blob)
---------------------------------------------------------------------------

local function encode_text_signature(id, phase)
  local payload = { v = 1, id = id }
  if phase then payload.phase = phase end
  return vim.json.encode(payload)
end

local function parse_text_signature(sig)
  if not sig or sig == "" then return nil end
  if sig:sub(1, 1) == "{" then
    local ok, parsed = pcall(vim.json.decode, sig)
    if ok and type(parsed) == "table" and parsed.v == 1 and type(parsed.id) == "string" then
      local out = { id = parsed.id }
      if parsed.phase == "commentary" or parsed.phase == "final_answer" then
        out.phase = parsed.phase
      end
      return out
    end
  end
  return { id = sig }
end

---------------------------------------------------------------------------
-- Tool-call ID normalisation helpers
---------------------------------------------------------------------------

local function normalize_id_part(part)
  local sanitized = part:gsub("[^a-zA-Z0-9_%-]", "_")
  if #sanitized > 64 then sanitized = sanitized:sub(1, 64) end
  sanitized = sanitized:gsub("_+$", "")
  return sanitized
end

local function build_foreign_responses_item_id(item_id)
  local short = "fc_" .. hash.short_hash(item_id)
  if #short > 64 then short = short:sub(1, 64) end
  return short
end

local function normalize_tool_call_id_for(model, allowed_providers)
  local allow = {}
  for _, p in ipairs(allowed_providers or {}) do allow[p] = true end

  return function(id, target_model, source)
    if not allow[target_model.provider] then
      return normalize_id_part(id)
    end
    if not id:find("|", 1, true) then
      return normalize_id_part(id)
    end
    local pipe = id:find("|", 1, true)
    local call_id = id:sub(1, pipe - 1)
    local item_id = id:sub(pipe + 1)
    local normalized_call = normalize_id_part(call_id)
    local is_foreign =
      source.provider ~= target_model.provider or source.api ~= target_model.api
    local normalized_item = is_foreign and build_foreign_responses_item_id(item_id)
                                        or normalize_id_part(item_id)
    if normalized_item:sub(1, 3) ~= "fc_" then
      normalized_item = normalize_id_part("fc_" .. normalized_item)
    end
    return normalized_call .. "|" .. normalized_item
  end
end

---------------------------------------------------------------------------
-- Message conversion
---------------------------------------------------------------------------

--- Convert a pi-ai Context to a list of Responses-style `input` items.
---@param model table                Target model.
---@param context table              pi-ai Context.
---@param allowed_tool_call_providers string[]  Providers whose tool-call IDs
---        contain the pipe-separated `call_id|item_id` form (openai, openai-codex, ...).
---@param opts? table                { include_system_prompt? }
---@return table[] messages
function M.convert_messages(model, context, allowed_tool_call_providers, opts)
  opts = opts or {}
  local include_system = opts.include_system_prompt
  if include_system == nil then include_system = true end

  local normalize = normalize_tool_call_id_for(model, allowed_tool_call_providers)
  local transformed = transform.transform(context.messages, model, normalize)

  local out = {}
  if include_system and context.system_prompt then
    local role = model.reasoning and "developer" or "system"
    table.insert(out, { role = role, content = sanitize.sanitize_surrogates(context.system_prompt) })
  end

  local msg_index = 0
  for _, msg in ipairs(transformed) do
    if msg.role == "user" then
      if type(msg.content) == "string" then
        table.insert(out, {
          role = "user",
          content = { { type = "input_text", text = sanitize.sanitize_surrogates(msg.content) } },
        })
      else
        local parts = {}
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(parts, { type = "input_text", text = sanitize.sanitize_surrogates(item.text) })
          elseif item.type == "image" then
            table.insert(parts, {
              type = "input_image",
              detail = "auto",
              image_url = "data:" .. item.mime_type .. ";base64," .. item.data,
            })
          end
        end
        if #parts > 0 then
          table.insert(out, { role = "user", content = parts })
        end
      end

    elseif msg.role == "assistant" then
      local is_different_model =
        msg.model ~= model.id
        and msg.provider == model.provider
        and msg.api == model.api

      local items = {}
      for _, block in ipairs(msg.content or {}) do
        if block.type == "thinking" then
          if block.thinking_signature and #block.thinking_signature > 0 then
            local ok, reasoning_item = pcall(vim.json.decode, block.thinking_signature)
            if ok and type(reasoning_item) == "table" then
              table.insert(items, reasoning_item)
            end
          end
        elseif block.type == "text" then
          local parsed_sig = parse_text_signature(block.text_signature)
          local msg_id = parsed_sig and parsed_sig.id
          if not msg_id then
            msg_id = "msg_" .. msg_index
          elseif #msg_id > 64 then
            msg_id = "msg_" .. hash.short_hash(msg_id)
          end
          table.insert(items, {
            type = "message",
            role = "assistant",
            content = { { type = "output_text", text = sanitize.sanitize_surrogates(block.text), annotations = {} } },
            status = "completed",
            id = msg_id,
            phase = parsed_sig and parsed_sig.phase,
          })
        elseif block.type == "toolCall" then
          local pipe = block.id:find("|", 1, true)
          local call_id = pipe and block.id:sub(1, pipe - 1) or block.id
          local item_id = pipe and block.id:sub(pipe + 1) or nil

          -- For different-model messages, drop fc_-prefixed item ids to avoid
          -- reasoning/tool-call pairing validation in OpenAI.
          if is_different_model and item_id and item_id:sub(1, 3) == "fc_" then
            item_id = nil
          end

          table.insert(items, {
            type = "function_call",
            id = item_id,
            call_id = call_id,
            name = block.name,
            arguments = json.encode_object(block.arguments or {}),
          })
        end
      end
      if #items > 0 then
        for _, item in ipairs(items) do table.insert(out, item) end
      end

    elseif msg.role == "toolResult" then
      local text_parts = {}
      local images = {}
      for _, c in ipairs(msg.content or {}) do
        if c.type == "text" then table.insert(text_parts, c.text)
        elseif c.type == "image" then table.insert(images, c) end
      end
      local text_result = table.concat(text_parts, "\n")
      local has_images = #images > 0
      local has_text = #text_result > 0
      local pipe = msg.tool_call_id:find("|", 1, true)
      local call_id = pipe and msg.tool_call_id:sub(1, pipe - 1) or msg.tool_call_id

      local output
      local supports_image = false
      for _, k in ipairs(model.input or {}) do if k == "image" then supports_image = true; break end end
      if has_images and supports_image then
        local parts = {}
        if has_text then
          table.insert(parts, { type = "input_text", text = sanitize.sanitize_surrogates(text_result) })
        end
        for _, img in ipairs(images) do
          table.insert(parts, {
            type = "input_image",
            detail = "auto",
            image_url = "data:" .. img.mime_type .. ";base64," .. img.data,
          })
        end
        output = parts
      else
        output = sanitize.sanitize_surrogates(has_text and text_result or "(see attached image)")
      end

      table.insert(out, {
        type = "function_call_output",
        call_id = call_id,
        output = output,
      })
    end
    msg_index = msg_index + 1
  end
  return out
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

--- Convert pi-ai tools to Responses-style function tools.
---@param tools table[]
---@param opts? table { strict? }
---@return table[]
function M.convert_tools(tools, opts)
  opts = opts or {}
  local strict = opts.strict
  if strict == nil then strict = false end

  local out = {}
  for _, tool in ipairs(tools or {}) do
    table.insert(out, {
      type = "function",
      name = tool.name,
      description = tool.description,
      parameters = tool.parameters,
      strict = strict,
    })
  end
  return out
end

---------------------------------------------------------------------------
-- Stop reason mapping
---------------------------------------------------------------------------

local function map_stop_reason(status)
  if not status or status == vim.NIL then return "stop" end
  if status == "completed" then return "stop" end
  if status == "incomplete" then return "length" end
  if status == "failed" or status == "cancelled" then return "error" end
  if status == "in_progress" or status == "queued" then return "stop" end
  return "stop"
end

---------------------------------------------------------------------------
-- Stream-event processing
---------------------------------------------------------------------------

--- Create a fresh per-stream state object.
---@param model table
---@param output table          AssistantMessage under construction
---@param es table              EventStream to push pi-ai events to
---@param opts? table           { service_tier, apply_service_tier_pricing }
---@return table state
function M.new_state(model, output, es, opts)
  return {
    model = model,
    output = output,
    es = es,
    current_item = nil,
    current_block = nil,
    service_tier = opts and opts.service_tier,
    apply_service_tier_pricing = opts and opts.apply_service_tier_pricing,
  }
end

local function bidx(state) return #state.output.content end

--- Process a single parsed Responses API event.
---@param evt table  the JSON-decoded event payload
---@param state table
---@return string|nil err  non-nil if the event signalled an error
function M.process_event(evt, state)
  local es = state.es
  local output = state.output
  local t = evt.type

  if t == "response.created" and evt.response then
    output.response_id = evt.response.id

  elseif t == "response.output_item.added" then
    local item = evt.item or {}
    if item.type == "reasoning" then
      state.current_item = item
      state.current_block = { type = "thinking", thinking = "" }
      table.insert(output.content, state.current_block)
      es:push({ type = "thinking_start", content_index = bidx(state), partial = output })
    elseif item.type == "message" then
      state.current_item = item
      state.current_block = { type = "text", text = "" }
      table.insert(output.content, state.current_block)
      es:push({ type = "text_start", content_index = bidx(state), partial = output })
    elseif item.type == "function_call" then
      state.current_item = item
      state.current_block = {
        type = "toolCall",
        id = (item.call_id or "") .. "|" .. (item.id or ""),
        name = item.name or "",
        arguments = {},
        _partial_json = item.arguments or "",
      }
      table.insert(output.content, state.current_block)
      es:push({ type = "toolcall_start", content_index = bidx(state), partial = output })
    end

  elseif t == "response.reasoning_summary_part.added" then
    if state.current_item and state.current_item.type == "reasoning" then
      state.current_item.summary = state.current_item.summary or {}
      table.insert(state.current_item.summary, evt.part)
    end

  elseif t == "response.reasoning_summary_text.delta" then
    if state.current_item and state.current_item.type == "reasoning"
        and state.current_block and state.current_block.type == "thinking" then
      state.current_item.summary = state.current_item.summary or {}
      local last = state.current_item.summary[#state.current_item.summary]
      if last then
        state.current_block.thinking = state.current_block.thinking .. evt.delta
        last.text = (last.text or "") .. evt.delta
        es:push({ type = "thinking_delta", content_index = bidx(state), delta = evt.delta, partial = output })
      end
    end

  elseif t == "response.reasoning_summary_part.done" then
    if state.current_item and state.current_item.type == "reasoning"
        and state.current_block and state.current_block.type == "thinking" then
      state.current_item.summary = state.current_item.summary or {}
      local last = state.current_item.summary[#state.current_item.summary]
      if last then
        state.current_block.thinking = state.current_block.thinking .. "\n\n"
        last.text = (last.text or "") .. "\n\n"
        es:push({ type = "thinking_delta", content_index = bidx(state), delta = "\n\n", partial = output })
      end
    end

  elseif t == "response.content_part.added" then
    if state.current_item and state.current_item.type == "message" then
      state.current_item.content = state.current_item.content or {}
      if evt.part and (evt.part.type == "output_text" or evt.part.type == "refusal") then
        table.insert(state.current_item.content, evt.part)
      end
    end

  elseif t == "response.output_text.delta" then
    if state.current_item and state.current_item.type == "message"
        and state.current_block and state.current_block.type == "text" then
      local content = state.current_item.content
      if content and #content > 0 then
        local last = content[#content]
        if last.type == "output_text" then
          state.current_block.text = state.current_block.text .. evt.delta
          last.text = (last.text or "") .. evt.delta
          es:push({ type = "text_delta", content_index = bidx(state), delta = evt.delta, partial = output })
        end
      end
    end

  elseif t == "response.refusal.delta" then
    if state.current_item and state.current_item.type == "message"
        and state.current_block and state.current_block.type == "text" then
      local content = state.current_item.content
      if content and #content > 0 then
        local last = content[#content]
        if last.type == "refusal" then
          state.current_block.text = state.current_block.text .. evt.delta
          last.refusal = (last.refusal or "") .. evt.delta
          es:push({ type = "text_delta", content_index = bidx(state), delta = evt.delta, partial = output })
        end
      end
    end

  elseif t == "response.function_call_arguments.delta" then
    if state.current_item and state.current_item.type == "function_call"
        and state.current_block and state.current_block.type == "toolCall" then
      state.current_block._partial_json = (state.current_block._partial_json or "") .. evt.delta
      state.current_block.arguments = json.parse_streaming_json(state.current_block._partial_json)
      es:push({ type = "toolcall_delta", content_index = bidx(state), delta = evt.delta, partial = output })
    end

  elseif t == "response.function_call_arguments.done" then
    if state.current_item and state.current_item.type == "function_call"
        and state.current_block and state.current_block.type == "toolCall" then
      local prev = state.current_block._partial_json or ""
      state.current_block._partial_json = evt.arguments or ""
      state.current_block.arguments = json.parse_streaming_json(state.current_block._partial_json)
      if evt.arguments and evt.arguments:sub(1, #prev) == prev then
        local d = evt.arguments:sub(#prev + 1)
        if #d > 0 then
          es:push({ type = "toolcall_delta", content_index = bidx(state), delta = d, partial = output })
        end
      end
    end

  elseif t == "response.output_item.done" then
    local item = evt.item or {}
    if item.type == "reasoning" and state.current_block and state.current_block.type == "thinking" then
      local parts = {}
      if type(item.summary) == "table" then
        for _, p in ipairs(item.summary) do table.insert(parts, p.text or "") end
      end
      state.current_block.thinking = table.concat(parts, "\n\n")
      state.current_block.thinking_signature = vim.json.encode(item)
      es:push({ type = "thinking_end", content_index = bidx(state),
                content = state.current_block.thinking, partial = output })
      state.current_block = nil
    elseif item.type == "message" and state.current_block and state.current_block.type == "text" then
      local parts = {}
      for _, c in ipairs(item.content or {}) do
        if c.type == "output_text" then table.insert(parts, c.text or "")
        elseif c.type == "refusal" then table.insert(parts, c.refusal or "") end
      end
      state.current_block.text = table.concat(parts, "")
      state.current_block.text_signature = encode_text_signature(item.id, item.phase)
      es:push({ type = "text_end", content_index = bidx(state),
                content = state.current_block.text, partial = output })
      state.current_block = nil
    elseif item.type == "function_call" then
      local args
      if state.current_block and state.current_block.type == "toolCall" and state.current_block._partial_json then
        args = json.parse_streaming_json(state.current_block._partial_json)
      else
        args = json.parse_streaming_json(item.arguments or "{}")
      end
      local tc
      if state.current_block and state.current_block.type == "toolCall" then
        state.current_block.arguments = args
        state.current_block._partial_json = nil
        tc = state.current_block
      else
        tc = {
          type = "toolCall",
          id = (item.call_id or "") .. "|" .. (item.id or ""),
          name = item.name or "",
          arguments = args,
        }
      end
      state.current_block = nil
      es:push({ type = "toolcall_end", content_index = bidx(state),
                tool_call = tc, partial = output })
    end

  elseif t == "response.completed" then
    local resp = evt.response or {}
    if resp.id then output.response_id = resp.id end
    if resp.usage then
      local cached = (resp.usage.input_tokens_details and resp.usage.input_tokens_details.cached_tokens) or 0
      local input = (resp.usage.input_tokens or 0) - cached
      output.usage = {
        input = input,
        output = resp.usage.output_tokens or 0,
        cache_read = cached,
        cache_write = 0,
        total_tokens = resp.usage.total_tokens or 0,
        reasoning_tokens = (resp.usage.output_tokens_details and resp.usage.output_tokens_details.reasoning_tokens) or 0,
        cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
      }
    end
    types.calculate_cost(state.model, output.usage)

    if state.apply_service_tier_pricing then
      local tier = resp.service_tier or state.service_tier
      state.apply_service_tier_pricing(output.usage, tier)
    end

    output.stop_reason = map_stop_reason(resp.status)
    if output.stop_reason == "stop" then
      for _, b in ipairs(output.content) do
        if b.type == "toolCall" then output.stop_reason = "toolUse"; break end
      end
    end

  elseif t == "error" then
    return string.format("Error Code %s: %s", tostring(evt.code or "unknown"), evt.message or "Unknown error")

  elseif t == "response.failed" then
    local err = evt.response and evt.response.error
    local details = evt.response and evt.response.incomplete_details
    if err then
      return string.format("%s: %s", err.code or "unknown", err.message or "no message")
    elseif details and details.reason then
      return "incomplete: " .. details.reason
    else
      return "Unknown error (no error details in response)"
    end
  end

  return nil
end

return M
