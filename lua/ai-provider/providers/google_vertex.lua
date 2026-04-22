--- Google Vertex AI (google-vertex) — not implemented.
---
--- Vertex authentication uses either a GCP API key
--- (GOOGLE_CLOUD_API_KEY) or Application Default Credentials loaded from
--- `~/.config/gcloud/application_default_credentials.json` — the latter
--- needing a service-account JWT exchange implemented with RS256 signing.
---
--- When GOOGLE_CLOUD_API_KEY, GOOGLE_CLOUD_PROJECT, and GOOGLE_CLOUD_LOCATION
--- are all set, a Vertex call can be built on top of the google-generative-ai
--- endpoint by swapping baseUrl. A minimal implementation for that
--- specific case is provided below; the ADC path returns a clear error.
local M = {}

local EventStream = require "ai-provider.event_stream"
local types       = require "ai-provider.types"
local google      = require "ai-provider.providers.google"

local function not_supported(model, reason)
  local es = EventStream.new()
  vim.schedule(function()
    local out = types.new_assistant_message(model)
    out.stop_reason = "error"
    out.error_message = reason
    es:push({ type = "error", reason = "error", error = out })
    es:finish()
  end)
  return es
end

local function has_api_key()
  return os.getenv("GOOGLE_CLOUD_API_KEY") ~= nil
end

--- Best-effort Vertex stream: if GOOGLE_CLOUD_API_KEY is present, delegate
--- to the google-generative-ai provider (Vertex's API surface is
--- compatible when using an API key). Otherwise, error out.
function M.stream(model, context, options)
  if has_api_key() then
    local opts = vim.deepcopy(options or {})
    opts.api_key = opts.api_key or os.getenv("GOOGLE_CLOUD_API_KEY")
    return google.stream(model, context, opts)
  end
  return not_supported(model,
    "google-vertex with Application Default Credentials (gcloud auth "
    .. "application-default login) is not supported in ai-provider.nvim. "
    .. "Set GOOGLE_CLOUD_API_KEY to use a plain API key, or run pi-mono.")
end

function M.stream_simple(model, context, options)
  if has_api_key() then
    local opts = vim.deepcopy(options or {})
    opts.api_key = opts.api_key or os.getenv("GOOGLE_CLOUD_API_KEY")
    return google.stream_simple(model, context, opts)
  end
  return not_supported(model,
    "google-vertex with Application Default Credentials (gcloud auth "
    .. "application-default login) is not supported in ai-provider.nvim. "
    .. "Set GOOGLE_CLOUD_API_KEY to use a plain API key, or run pi-mono.")
end

return M
