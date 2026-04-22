--- Google Gemini CLI (google-gemini-cli) — not implemented.
---
--- The upstream provider authenticates through a long-lived OAuth token
--- cached in `~/.gemini/oauth_creds.json` by the `gemini` CLI, then hits
--- the CloudCode internal generateContent endpoint. Replicating the CLI's
--- OAuth refresh + session loading is non-trivial and unsuitable for a
--- Neovim plugin (~1000 LOC of refresh / code-server shims).
---
--- Users who want Gemini should use the `google` provider
--- (google-generative-ai / `GEMINI_API_KEY`) instead.
local M = {}

local EventStream = require "ai-provider.event_stream"
local types       = require "ai-provider.types"

local function not_supported(model)
  local es = EventStream.new()
  vim.schedule(function()
    local out = types.new_assistant_message(model)
    out.stop_reason = "error"
    out.error_message = "google-gemini-cli is not implemented in "
      .. "ai-provider.nvim. Use the `google` provider with GEMINI_API_KEY "
      .. "(api = \"google-generative-ai\") or run pi-mono."
    es:push({ type = "error", reason = "error", error = out })
    es:finish()
  end)
  return es
end

function M.stream(model)         return not_supported(model) end
function M.stream_simple(model)  return not_supported(model) end

return M
