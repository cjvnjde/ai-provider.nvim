--- Anthropic Messages API streaming provider.
---
--- Covers: Anthropic direct (API key OR sk-ant-oat OAuth), GitHub Copilot
---         (Claude models). Handles extended thinking (budget + adaptive),
---         cache control (cacheRetention → ephemeral cache breakpoints),
---         cross-provider message replay via transform_messages, and the
---         per-tool `eager_input_streaming` flag that replaced the
---         fine-grained-tool-streaming beta header.
---
--- Mirrors pi-mono packages/ai/src/providers/anthropic.ts.
local M = {}

local EventStream  = require "ai-provider.event_stream"
local curl_stream  = require "ai-provider.curl_stream"
local types        = require "ai-provider.types"
local env_keys     = require "ai-provider.env_keys"
local utils        = require "ai-provider.utils"
local transform    = utils.transform
local sanitize     = utils.sanitize

---------------------------------------------------------------------------
-- Claude Code identity (used when an OAuth token is detected).
---------------------------------------------------------------------------

local CLAUDE_CODE_VERSION = "2.1.75"
local CLAUDE_CODE_TOOLS = {
  "Read", "Write", "Edit", "Bash", "Grep", "Glob", "AskUserQuestion",
  "EnterPlanMode", "ExitPlanMode", "KillShell", "NotebookEdit",
  "Skill", "Task", "TaskOutput", "TodoWrite", "WebFetch", "WebSearch",
}
local CC_TOOL_LOOKUP = {}
for _, n in ipairs(CLAUDE_CODE_TOOLS) do CC_TOOL_LOOKUP[n:lower()] = n end

local function to_claude_code_name(name)
  return CC_TOOL_LOOKUP[tostring(name):lower()] or name
end

local function is_oauth_token(api_key)
  return type(api_key) == "string" and api_key:find("sk%-ant%-oat") ~= nil
end

---------------------------------------------------------------------------
-- Cache-retention helpers
---------------------------------------------------------------------------

local function resolve_cache_retention(retention)
  if retention then return retention end
  if os.getenv("PI_CACHE_RETENTION") == "long" then return "long" end
  return "short"
end

local function get_cache_control(base_url, retention)
  retention = resolve_cache_retention(retention)
  if retention == "none" then return nil, retention end
  local cc = { type = "ephemeral" }
  if retention == "long" and (base_url or ""):find("api%.anthropic%.com") then
    cc.ttl = "1h"
  end
  return cc, retention
end

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
      or model_id:find("opus%-4%.7") or model_id:find("opus%-4%-7")
      or model_id:find("sonnet%-4%.6") or model_id:find("sonnet%-4%-6")
end

local function map_thinking_level_to_effort(level, model_id)
  if level == "minimal" or level == "low" then return "low" end
  if level == "medium" then return "medium" end
  if level == "xhigh" then
    if model_id:find("opus%-4%.6") or model_id:find("opus%-4%-6") then return "max" end
    if model_id:find("opus%-4%.7") or model_id:find("opus%-4%-7") then return "xhigh" end
    return "high"
  end
  return "high"
end

---------------------------------------------------------------------------
-- Content-block helpers
---------------------------------------------------------------------------

local function convert_tool_result_content(content)
  local has_images = false
  for _, c in ipairs(content or {}) do if c.type == "image" then has_images = true; break end end

  if not has_images then
    local text = {}
    for _, c in ipairs(content or {}) do
      if c.type == "text" then table.insert(text, c.text) end
    end
    return sanitize.sanitize_surrogates(table.concat(text, "\n"))
  end

  local blocks = {}
  local has_text = false
  for _, b in ipairs(content or {}) do
    if b.type == "text" then
      table.insert(blocks, { type = "text", text = sanitize.sanitize_surrogates(b.text) })
      has_text = true
    elseif b.type == "image" then
      table.insert(blocks, {
        type = "image",
        source = { type = "base64", media_type = b.mime_type, data = b.data },
      })
    end
  end
  if not has_text then
    table.insert(blocks, 1, { type = "text", text = "(see attached image)" })
  end
  return blocks
end

---------------------------------------------------------------------------
-- Tool-call ID normalisation
---------------------------------------------------------------------------

local function normalize_tool_call_id(id)
  return (tostring(id):gsub("[^a-zA-Z0-9_%-]", "_")):sub(1, 64)
end

---------------------------------------------------------------------------
-- Tool conversion
---------------------------------------------------------------------------

local function convert_tools(tools, is_oauth, cache_control)
  if not tools or #tools == 0 then return nil end
  local out = {}
  for i, tool in ipairs(tools) do
    local schema = tool.parameters or {}
    local entry = {
      name = is_oauth and to_claude_code_name(tool.name) or tool.name,
      description = tool.description,
      eager_input_streaming = true,
      input_schema = {
        type = "object",
        properties = schema.properties or {},
        required = schema.required or {},
      },
    }
    if cache_control and i == #tools then
      entry.cache_control = cache_control
    end
    table.insert(out, entry)
  end
  return out
end

---------------------------------------------------------------------------
-- Message conversion (uses transform_messages)
---------------------------------------------------------------------------

local function convert_messages(context_messages, model, is_oauth, cache_control)
  local transformed = transform.transform(context_messages, model, normalize_tool_call_id)
  local params = {}

  local i = 1
  while i <= #transformed do
    local msg = transformed[i]

    if msg.role == "user" then
      if type(msg.content) == "string" then
        if #msg.content:gsub("^%s+", ""):gsub("%s+$", "") > 0 then
          table.insert(params, { role = "user", content = sanitize.sanitize_surrogates(msg.content) })
        end
      else
        local blocks = {}
        for _, item in ipairs(msg.content) do
          if item.type == "text" then
            table.insert(blocks, { type = "text", text = sanitize.sanitize_surrogates(item.text) })
          elseif item.type == "image" then
            table.insert(blocks, {
              type = "image",
              source = { type = "base64", media_type = item.mime_type, data = item.data },
            })
          end
        end
        -- Drop empty text blocks only (images always kept).
        local filtered = {}
        for _, b in ipairs(blocks) do
          if not (b.type == "text" and #b.text:gsub("^%s+", ""):gsub("%s+$", "") == 0) then
            table.insert(filtered, b)
          end
        end
        if #filtered > 0 then
          table.insert(params, { role = "user", content = filtered })
        end
      end

    elseif msg.role == "assistant" then
      local blocks = {}
      for _, b in ipairs(msg.content or {}) do
        if b.type == "text" then
          if (b.text or ""):match("%S") then
            table.insert(blocks, { type = "text", text = sanitize.sanitize_surrogates(b.text) })
          end
        elseif b.type == "thinking" then
          if b.redacted then
            table.insert(blocks, { type = "redacted_thinking", data = b.thinking_signature })
          elseif (b.thinking or ""):match("%S") then
            if not b.thinking_signature or (b.thinking_signature or ""):match("^%s*$") then
              table.insert(blocks, { type = "text", text = sanitize.sanitize_surrogates(b.thinking) })
            else
              table.insert(blocks, {
                type = "thinking",
                thinking = sanitize.sanitize_surrogates(b.thinking),
                signature = b.thinking_signature,
              })
            end
          end
        elseif b.type == "toolCall" then
          local input = b.arguments
          if input == nil or (type(input) == "table" and next(input) == nil) then
            input = vim.empty_dict()
          end
          table.insert(blocks, {
            type = "tool_use",
            id = b.id,
            name = is_oauth and to_claude_code_name(b.name) or b.name,
            input = input,
          })
        end
      end
      if #blocks > 0 then
        table.insert(params, { role = "assistant", content = blocks })
      end

    elseif msg.role == "toolResult" then
      local tool_results = { {
        type = "tool_result",
        tool_use_id = msg.tool_call_id,
        content = convert_tool_result_content(msg.content),
        is_error = msg.is_error,
      } }
      local j = i + 1
      while j <= #transformed and transformed[j].role == "toolResult" do
        local next_msg = transformed[j]
        table.insert(tool_results, {
          type = "tool_result",
          tool_use_id = next_msg.tool_call_id,
          content = convert_tool_result_content(next_msg.content),
          is_error = next_msg.is_error,
        })
        j = j + 1
      end
      i = j - 1
      table.insert(params, { role = "user", content = tool_results })
    end
    i = i + 1
  end

  -- Add cache_control to the last user message for prompt caching.
  if cache_control and #params > 0 then
    local last = params[#params]
    if last.role == "user" then
      if type(last.content) == "table" then
        local last_block = last.content[#last.content]
        if last_block and (last_block.type == "text" or last_block.type == "image" or last_block.type == "tool_result") then
          last_block.cache_control = cache_control
        end
      elseif type(last.content) == "string" then
        last.content = { { type = "text", text = last.content, cache_control = cache_control } }
      end
    end
  end
  return params
end

---------------------------------------------------------------------------
-- Build request body
---------------------------------------------------------------------------

local function build_body(model, context, options, is_oauth)
  options = options or {}
  local cache_control = select(1, get_cache_control(model.base_url, options.cache_retention))
  local body = {
    model = model.id,
    messages = convert_messages(context.messages, model, is_oauth, cache_control),
    max_tokens = options.max_tokens or math.floor((model.max_tokens or 32000) / 3),
    stream = true,
  }

  -- System prompt (+ Claude Code identity for OAuth tokens).
  if is_oauth then
    body.system = {
      {
        type = "text",
        text = "You are Claude Code, Anthropic's official CLI for Claude.",
        cache_control = cache_control,
      },
    }
    if context.system_prompt then
      table.insert(body.system, {
        type = "text",
        text = sanitize.sanitize_surrogates(context.system_prompt),
        cache_control = cache_control,
      })
    end
  elseif context.system_prompt then
    body.system = {
      { type = "text", text = sanitize.sanitize_surrogates(context.system_prompt), cache_control = cache_control },
    }
  end

  -- Temperature is incompatible with extended thinking.
  if options.temperature ~= nil and not options.thinking_enabled then
    body.temperature = options.temperature
  end

  -- Tools
  if context.tools and #context.tools > 0 then
    body.tools = convert_tools(context.tools, is_oauth, cache_control)
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
      local display = options.thinking_display or "summarized"
      if supports_adaptive(model.id) then
        body.thinking = { type = "adaptive", display = display }
        if options.effort then
          body.output_config = { effort = options.effort }
        end
      else
        body.thinking = {
          type = "enabled",
          budget_tokens = options.thinking_budget_tokens or 1024,
          display = display,
        }
      end
    elseif options.thinking_enabled == false then
      body.thinking = { type = "disabled" }
    end
  end

  -- Metadata (pi-mono only passes through user_id)
  if options.metadata and type(options.metadata.user_id) == "string" then
    body.metadata = { user_id = options.metadata.user_id }
  end

  -- Payload hook
  if options.on_payload then
    local nb = options.on_payload(body, model)
    if nb ~= nil then body = nb end
  end
  return body
end

---------------------------------------------------------------------------
-- Headers
---------------------------------------------------------------------------

local function build_headers(model, api_key, options, is_oauth)
  local h = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
    ["accept"] = "application/json",
  }

  local betas = {}
  if not supports_adaptive(model.id) then
    table.insert(betas, "interleaved-thinking-2025-05-14")
  end

  if model.provider == "github-copilot" then
    h["Authorization"] = "Bearer " .. api_key
    h["anthropic-dangerous-direct-browser-access"] = "true"
  elseif is_oauth then
    h["Authorization"] = "Bearer " .. api_key
    h["anthropic-dangerous-direct-browser-access"] = "true"
    h["user-agent"] = "claude-cli/" .. CLAUDE_CODE_VERSION
    h["x-app"] = "cli"
    table.insert(betas, 1, "claude-code-20250219")
    table.insert(betas, 2, "oauth-2025-04-20")
  else
    h["x-api-key"] = api_key
    h["anthropic-dangerous-direct-browser-access"] = "true"
  end

  if #betas > 0 then
    h["anthropic-beta"] = table.concat(betas, ",")
  end

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
      local is_oauth = is_oauth_token(api_key)
      local base_url = resolved_base_url or model.base_url
      if base_url:sub(-1) == "/" then base_url = base_url:sub(1, -2) end
      local endpoint = base_url .. "/v1/messages"
      local headers  = build_headers(model, api_key, options, is_oauth)
      local body     = build_body(model, context, options, is_oauth)

      local output = types.new_assistant_message(model)
      local blocks_by_index = {}
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
            output.usage.input        = u.input_tokens or 0
            output.usage.output       = u.output_tokens or 0
            output.usage.cache_read   = u.cache_read_input_tokens or 0
            output.usage.cache_write  = u.cache_creation_input_tokens or 0
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
              local block = { type = "thinking", thinking = "[Reasoning redacted]",
                              thinking_signature = cb.data, redacted = true }
              table.insert(output.content, block)
              blocks_by_index[idx] = { block = block, our_index = #output.content }
              es:push({ type = "thinking_start", content_index = #output.content, partial = output })
            elseif cb.type == "tool_use" then
              local block = { type = "toolCall", id = cb.id or "", name = cb.name or "",
                              arguments = cb.input or {}, _partial_json = "" }
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
            if d.stop_reason then output.stop_reason = map_stop_reason(d.stop_reason) end
            local u = evt.usage or {}
            if u.input_tokens then output.usage.input = u.input_tokens end
            if u.output_tokens then output.usage.output = u.output_tokens end
            if u.cache_read_input_tokens then output.usage.cache_read = u.cache_read_input_tokens end
            if u.cache_creation_input_tokens then output.usage.cache_write = u.cache_creation_input_tokens end
            output.usage.total_tokens = output.usage.input + output.usage.output
              + output.usage.cache_read + output.usage.cache_write
            types.calculate_cost(model, output.usage)

          elseif etype == "message_stop" then
            if output.stop_reason ~= "error" and output.stop_reason ~= "aborted" then
              es:push({ type = "done", reason = output.stop_reason, message = output })
            else
              es:push({ type = "error", reason = output.stop_reason, error = output })
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
            output.error_message = (eok and edata and edata.error and edata.error.message) or raw
            es:push({ type = "error", reason = "error", error = output })
            es:finish(); return
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
    thinking_display = options.thinking_display,
  }

  if not options.reasoning then
    base.thinking_enabled = false
    return M.stream(model, context, base)
  end

  if supports_adaptive(model.id) then
    base.thinking_enabled = true
    base.effort = map_thinking_level_to_effort(options.reasoning, model.id)
    return M.stream(model, context, base)
  end

  local max_tok, budget = types.adjust_max_tokens_for_thinking(
    base.max_tokens or 0, model.max_tokens or 64000, options.reasoning, options.thinking_budgets
  )
  base.max_tokens = max_tok
  base.thinking_enabled = true
  base.thinking_budget_tokens = budget
  return M.stream(model, context, base)
end

return M
