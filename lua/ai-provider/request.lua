--- HTTP request helper – resolves auth via the provider then sends a POST.
local M = {}

local function get_host(endpoint)
  return endpoint and endpoint:match("^https?://([^/%?]+)") or "unknown-host"
end

local function format_request_target(opts, endpoint)
  local label = opts.label and (opts.label .. " -> ") or ""
  local provider = opts.provider or "unknown-provider"
  local model = opts.model or (opts.body and opts.body.model) or "unknown-model"
  local host = get_host(endpoint)
  return string.format("%s%s / %s -> %s", label, provider, model, host)
end

local function encode_request_body(body)
  if body == nil then
    return nil
  end

  if type(body) == "string" then
    return body
  end

  local ok, encoded = pcall(vim.json.encode, body)

  if ok then
    return encoded
  end

  return nil, "Failed to encode request body: " .. tostring(encoded)
end

local function write_request_body_file(body)
  local encoded, err = encode_request_body(body)

  if err then
    return nil, err
  end

  if encoded == nil then
    return nil
  end

  local path = vim.fn.tempname()
  local f, open_err = io.open(path, "wb")

  if not f then
    return nil, "Failed to create temp request body file: " .. tostring(open_err)
  end

  local ok, write_err = pcall(function()
    f:write(encoded)
  end)
  f:close()

  if not ok then
    pcall(os.remove, path)
    return nil, "Failed to write temp request body file: " .. tostring(write_err)
  end

  return path
end

--- Send a chat-completions request through a provider.
---
--- @param opts table { provider: string, model: string, body: table, label?: string }
---   `body` is the full JSON payload (model, messages, max_tokens, …).
---   The caller is responsible for constructing it.
---   `label` is an optional human-readable source tag shown in notifications.
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

    local body_file, body_err = write_request_body_file(opts.body)

    if body_err then
      vim.schedule(function()
        callback(nil, body_err)
      end)
      return
    end

    local cleaned = false

    local function cleanup_body_file()
      if cleaned or not body_file then
        return
      end

      cleaned = true
      pcall(os.remove, body_file)
    end

    local notification = require "ai-provider.notification"
    local target_label = format_request_target(opts, endpoint)

    vim.schedule(function()
      notification.show("Sending: " .. target_label)
    end)

    local ok, request_err = pcall(function()
      require("plenary.curl").post(endpoint, {
        headers = headers,
        -- Use a temp file so large prompts do not exceed argv per-argument limits.
        body = body_file,
        callback = vim.schedule_wrap(function(response)
          cleanup_body_file()
          notification.dismiss()
          callback(response)
        end),
        on_error = vim.schedule_wrap(function(curl_err)
          cleanup_body_file()
          notification.dismiss()
          local msg = type(curl_err) == "table" and (curl_err.message or curl_err.stderr) or tostring(curl_err)
          callback(nil, msg)
        end),
      })
    end)

    if not ok then
      cleanup_body_file()
      vim.schedule(function()
        notification.dismiss()
        callback(nil, tostring(request_err))
      end)
    end
  end)
end

return M
