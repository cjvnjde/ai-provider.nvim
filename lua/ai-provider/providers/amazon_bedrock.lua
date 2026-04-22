--- Amazon Bedrock (bedrock-converse-stream) — not implemented.
---
--- Bedrock requires AWS SigV4 request signing (AWS_ACCESS_KEY_ID +
--- AWS_SECRET_ACCESS_KEY or a bearer token scoped to Bedrock), plus its
--- own InvokeModelWithResponseStream / ConverseStream event framing.
--- The SigV4 signer alone is ~300 LOC of crypto in any language and
--- isn't practical to add here without an HMAC-SHA256 dependency.
---
--- Users who want to call Bedrock can:
---   * Proxy Bedrock through an OpenAI-compatible gateway (e.g. LiteLLM,
---     Vercel AI Gateway) and add those models via `custom_models` with
---     api = "openai-completions".
---   * Or run pi-mono directly.
local M = {}

local EventStream = require "ai-provider.event_stream"
local types       = require "ai-provider.types"

local function not_supported(model)
  local es = EventStream.new()
  vim.schedule(function()
    local out = types.new_assistant_message(model)
    out.stop_reason = "error"
    out.error_message = "Amazon Bedrock (bedrock-converse-stream) is not "
      .. "implemented in ai-provider.nvim: AWS SigV4 signing is out of "
      .. "scope. Proxy via an OpenAI-compatible gateway or run pi-mono."
    es:push({ type = "error", reason = "error", error = out })
    es:finish()
  end)
  return es
end

function M.stream(model)         return not_supported(model) end
function M.stream_simple(model)  return not_supported(model) end

return M
