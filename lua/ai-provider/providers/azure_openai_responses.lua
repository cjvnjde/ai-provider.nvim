--- Azure OpenAI Responses streaming provider.
---
--- Thin wrapper over the OpenAI Responses API with Azure-specific URL /
--- api-version / deployment-name handling + `api-key` header auth.
---
--- Mirrors pi-mono packages/ai/src/providers/azure-openai-responses.ts.
local M = {}

local EventStream = require "ai-provider.event_stream"
local curl_stream = require "ai-provider.curl_stream"
local types       = require "ai-provider.types"
local env_keys    = require "ai-provider.env_keys"
local shared      = require "ai-provider.providers.openai_responses_shared"

local DEFAULT_API_VERSION = "v1"
local AZURE_TOOL_CALL_PROVIDERS = {
  "openai", "openai-codex", "opencode", "azure-openai-responses",
}

local function parse_deployment_name_map(value)
  local m = {}
  if not value then return m end
  for entry in value:gmatch("([^,]+)") do
    local trimmed = entry:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      local model_id, deployment = trimmed:match("^(.-)=(.*)$")
      if model_id and deployment then
        m[model_id:match("^%s*(.-)%s*$")] = deployment:match("^%s*(.-)%s*$")
      end
    end
  end
  return m
end

local function resolve_deployment_name(model, options)
  if options and options.azure_deployment_name then return options.azure_deployment_name end
  local mapped = parse_deployment_name_map(os.getenv("AZURE_OPENAI_DEPLOYMENT_NAME_MAP"))[model.id]
  return mapped or model.id
end

local function normalize_base_url(url)
  return (url:gsub("/+$", ""))
end

local function build_default_base_url(resource)
  return "https://" .. resource .. ".openai.azure.com/openai/v1"
end

local function resolve_azure_config(model, options)
  local api_version = (options and options.azure_api_version)
    or os.getenv("AZURE_OPENAI_API_VERSION")
    or DEFAULT_API_VERSION

  local base_url = options and options.azure_base_url
  if base_url then base_url = base_url:gsub("^%s+", ""):gsub("%s+$", "") end
  if not base_url or base_url == "" then
    local env_base = os.getenv("AZURE_OPENAI_BASE_URL")
    if env_base and env_base ~= "" then base_url = env_base:gsub("^%s+", ""):gsub("%s+$", "") end
  end
  local resource = (options and options.azure_resource_name) or os.getenv("AZURE_OPENAI_RESOURCE_NAME")

  if (not base_url or base_url == "") and resource then
    base_url = build_default_base_url(resource)
  end
  if (not base_url or base_url == "") and model.base_url and model.base_url ~= "" then
    base_url = model.base_url
  end
  if not base_url or base_url == "" then
    error("Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL / AZURE_OPENAI_RESOURCE_NAME or options.azure_base_url.")
  end

  return normalize_base_url(base_url), api_version
end

local function build_headers(model, api_key, options)
  local h = {
    ["Content-Type"] = "application/json",
    ["api-key"] = api_key,
    ["Accept"] = "text/event-stream",
  }
  if model.headers then for k, v in pairs(model.headers) do h[k] = v end end
  if options and options.headers then for k, v in pairs(options.headers) do h[k] = v end end
  return h
end

local function build_body(model, context, options, deployment_name)
  options = options or {}
  local messages = shared.convert_messages(model, context, AZURE_TOOL_CALL_PROVIDERS)
  local body = {
    model = deployment_name,
    input = messages,
    stream = true,
    prompt_cache_key = options.session_id,
  }

  if options.max_tokens then body.max_output_tokens = options.max_tokens end
  if options.temperature ~= nil then body.temperature = options.temperature end

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
    else
      body.reasoning = { effort = "none" }
    end
  end

  if options.on_payload then
    local nb = options.on_payload(body, model)
    if nb ~= nil then body = nb end
  end

  return body
end

local function resolve_api_key(options)
  if options and options.api_key then return options.api_key end
  return env_keys.get("azure-openai-responses") or os.getenv("AZURE_OPENAI_API_KEY")
end

--- Stream via Azure OpenAI Responses.
function M.stream(model, context, options)
  options = options or {}
  local es = EventStream.new()

  vim.schedule(function()
    local api_key = resolve_api_key(options)
    if not api_key then
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = "No API key for Azure OpenAI. Set AZURE_OPENAI_API_KEY."
      es:push({ type = "error", reason = "error", error = out })
      es:finish()
      return
    end

    local ok_cfg, base_url, api_version = pcall(resolve_azure_config, model, options)
    if not ok_cfg then
      local out = types.new_assistant_message(model)
      out.stop_reason = "error"
      out.error_message = tostring(base_url) -- contains error msg
      es:push({ type = "error", reason = "error", error = out })
      es:finish()
      return
    end

    local deployment = resolve_deployment_name(model, options)
    local endpoint = base_url .. "/responses?api-version=" .. api_version
    local headers  = build_headers(model, api_key, options)
    local body     = build_body(model, context, options, deployment)

    local output   = types.new_assistant_message(model)
    local state    = shared.new_state(model, output, es)
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
        if not evt.type and event_type then evt.type = event_type end
        if evt.error and not evt.type then
          output.stop_reason = "error"
          output.error_message = evt.error.message or vim.json.encode(evt.error)
          es:push({ type = "error", reason = "error", error = output })
          es:finish(); return
        end
        local err = shared.process_event(evt, state)
        if err then
          output.stop_reason = "error"; output.error_message = err
          es:push({ type = "error", reason = "error", error = output })
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
    api_key      = options.api_key,
    temperature  = options.temperature,
    max_tokens   = options.max_tokens or (model.max_tokens and math.min(model.max_tokens, 32000) or nil),
    headers      = options.headers,
    session_id   = options.session_id,
    on_payload   = options.on_payload,
    azure_api_version     = options.azure_api_version,
    azure_base_url        = options.azure_base_url,
    azure_resource_name   = options.azure_resource_name,
    azure_deployment_name = options.azure_deployment_name,
  }
  if options.reasoning then
    base.reasoning_effort = types.supports_xhigh(model) and options.reasoning or types.clamp_reasoning(options.reasoning)
  end
  return M.stream(model, context, base)
end

return M
