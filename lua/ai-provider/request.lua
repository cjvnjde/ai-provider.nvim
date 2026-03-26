--- HTTP request helper – resolves auth via the provider then sends a POST.
local M = {}

--- Send a chat-completions request through a provider.
---
--- @param opts table { provider: string, model: string, body: table }
---   `body` is the full JSON payload (model, messages, max_tokens, …).
---   The caller is responsible for constructing it.
--- @param callback fun(response: table|nil, err: string|nil)
---   On success `response` is the raw plenary.curl response
---   ({ status, body, headers }).  On auth failure `response` is nil.
function M.send(opts, callback)
  local provider_registry = require "ai-provider.providers"
  local provider = provider_registry.get(opts.provider)

  if not provider then
    vim.schedule(function()
      callback(nil, "Unknown provider: " .. tostring(opts.provider))
    end)
    return
  end

  provider.prepare_request(opts.model, function(endpoint, headers, err)
    if not endpoint then
      callback(nil, err or "Failed to prepare request")
      return
    end

    vim.schedule(function()
      vim.notify("Sending request to " .. opts.provider .. "...", vim.log.levels.INFO)
    end)

    require("plenary.curl").post(endpoint, {
      headers = headers,
      body = vim.json.encode(opts.body),
      callback = vim.schedule_wrap(function(response)
        callback(response)
      end),
    })
  end)
end

return M
