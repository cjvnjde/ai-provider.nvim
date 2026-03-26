--- GitHub Copilot provider – OAuth device-code flow + token management.
local M = {}

local curl = require "plenary.curl"
local config = require "ai-provider.config"
local store = require "ai-provider.credential_store"
local models_data = require "ai-provider.models"

local PROVIDER_NAME = "github-copilot"
local CLIENT_ID = "Iv1.b507a08c87ecfe98"

local COPILOT_HEADERS = {
  ["User-Agent"] = "GitHubCopilotChat/0.35.0",
  ["Editor-Version"] = "vscode/1.107.0",
  ["Editor-Plugin-Version"] = "copilot-chat/0.35.0",
  ["Copilot-Integration-Id"] = "vscode-chat",
}

--- Expose Copilot-specific headers for consumers that need them.
M.COPILOT_HEADERS = COPILOT_HEADERS

--- Get the enterprise domain from provider config (or nil for github.com).
local function get_enterprise_domain()
  local cfg = config.get_provider_config(PROVIDER_NAME)
  return cfg.enterprise_domain
end

---------------------------------------------------------------------------
-- Token helpers
---------------------------------------------------------------------------

--- Check whether the cached session token has expired (with 5-minute buffer).
local function needs_refresh(creds)
  if not creds or not creds.expires then
    return true
  end
  return os.time() >= creds.expires
end

--- Extract base API URL from the session token's proxy-ep field.
local function get_base_url(access_token, enterprise_domain)
  if access_token then
    local proxy_ep = access_token:match "proxy%-ep=([^;]+)"
    if proxy_ep then
      local api_host = proxy_ep:gsub("^proxy%.", "api.")
      return "https://" .. api_host
    end
  end
  if enterprise_domain then
    return "https://copilot-api." .. enterprise_domain
  end
  return "https://api.individual.githubcopilot.com"
end

---------------------------------------------------------------------------
-- Token exchange & refresh
---------------------------------------------------------------------------

--- Exchange a GitHub OAuth token for a short-lived Copilot session token.
local function exchange_for_copilot_token(github_token, enterprise_domain, callback)
  local domain = enterprise_domain or "github.com"
  local url = string.format("https://api.%s/copilot_internal/v2/token", domain)

  local headers = vim.tbl_extend("force", {
    accept = "application/json",
    authorization = "Bearer " .. github_token,
  }, COPILOT_HEADERS)

  curl.get(url, {
    headers = headers,
    callback = vim.schedule_wrap(function(response)
      if response.status == 200 then
        local ok, data = pcall(vim.json.decode, response.body)
        if ok and data and data.token and data.expires_at then
          local creds = {
            refresh_token = github_token,
            access_token = data.token,
            expires = data.expires_at - 5 * 60,
            enterprise_domain = enterprise_domain,
          }
          store.write(PROVIDER_NAME, creds)
          callback(creds)
        else
          callback(nil, "Failed to parse Copilot token response")
        end
      else
        callback(nil, "Failed to exchange token (status " .. tostring(response.status) .. ")")
      end
    end),
  })
end

---------------------------------------------------------------------------
-- Device-code OAuth flow
---------------------------------------------------------------------------

--- Recursive poller – calls itself via vim.defer_fn until the user authorises.
local function poll_for_access_token(domain, device_code, interval_ms, deadline, enterprise_domain, callback)
  if os.time() >= deadline then
    callback(nil, "GitHub device flow timed out. Please try again.")
    return
  end

  vim.defer_fn(function()
    local url = string.format("https://%s/login/oauth/access_token", domain)

    curl.post(url, {
      headers = {
        accept = "application/json",
        content_type = "application/x-www-form-urlencoded",
        ["User-Agent"] = "GitHubCopilotChat/0.35.0",
      },
      body = string.format(
        "client_id=%s&device_code=%s&grant_type=%s",
        CLIENT_ID,
        device_code,
        "urn:ietf:params:oauth:grant-type:device_code"
      ),
      callback = vim.schedule_wrap(function(response)
        local ok, data = pcall(vim.json.decode, response.body)
        if not ok or not data then
          callback(nil, "Failed to parse token poll response")
          return
        end

        if data.access_token then
          vim.notify("GitHub authentication successful! Obtaining Copilot token...", vim.log.levels.INFO)
          exchange_for_copilot_token(data.access_token, enterprise_domain, callback)
        elseif data.error == "authorization_pending" then
          poll_for_access_token(domain, device_code, interval_ms, deadline, enterprise_domain, callback)
        elseif data.error == "slow_down" then
          local new_interval = ((data.interval or math.ceil(interval_ms / 1000)) + 5) * 1000
          poll_for_access_token(domain, device_code, new_interval, deadline, enterprise_domain, callback)
        else
          callback(nil, "GitHub authentication failed: " .. (data.error_description or data.error or "Unknown error"))
        end
      end),
    })
  end, interval_ms)
end

---------------------------------------------------------------------------
-- Public provider interface
---------------------------------------------------------------------------

--- Start the device-code OAuth flow and call back with credentials.
---@param callback fun(creds: table|nil, err: string|nil)
function M.login(callback)
  local enterprise_domain = get_enterprise_domain()
  local domain = enterprise_domain or "github.com"
  local url = string.format("https://%s/login/device/code", domain)

  vim.notify("Starting GitHub Copilot authentication...", vim.log.levels.INFO)

  curl.post(url, {
    headers = {
      accept = "application/json",
      content_type = "application/x-www-form-urlencoded",
      ["User-Agent"] = "GitHubCopilotChat/0.35.0",
    },
    body = "client_id=" .. CLIENT_ID .. "&scope=read:user",
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        callback(nil, "Failed to start device flow (status " .. tostring(response.status) .. ")")
        return
      end

      local ok, data = pcall(vim.json.decode, response.body)
      if not ok or not data or not data.device_code then
        callback(nil, "Failed to parse device code response")
        return
      end

      vim.notify(
        string.format(
          "GitHub Copilot Login:\n  1. Open: %s\n  2. Enter code: %s\n\nWaiting for authentication...",
          data.verification_uri,
          data.user_code
        ),
        vim.log.levels.WARN
      )

      -- Try to open browser
      local open_cmd
      if vim.fn.has "mac" == 1 then
        open_cmd = "open"
      elseif vim.fn.has "unix" == 1 then
        open_cmd = "xdg-open"
      elseif vim.fn.has "win32" == 1 then
        open_cmd = "start"
      end
      if open_cmd then
        vim.fn.jobstart({ open_cmd, data.verification_uri }, { detach = true })
      end

      local interval_ms = math.max(1000, (data.interval or 5) * 1000)
      local deadline = os.time() + (data.expires_in or 900)
      poll_for_access_token(domain, data.device_code, interval_ms, deadline, enterprise_domain, callback)
    end),
  })
end

--- Remove stored credentials.
function M.logout()
  store.clear(PROVIDER_NAME)
  vim.notify("GitHub Copilot credentials cleared.", vim.log.levels.INFO)
end

--- Return current authentication status.
---@return table
function M.status()
  local creds = store.read(PROVIDER_NAME)

  if not creds then
    return { authenticated = false, provider = PROVIDER_NAME, message = "Not authenticated. Run login." }
  end

  if needs_refresh(creds) then
    return { authenticated = true, provider = PROVIDER_NAME, message = "Token expired (will auto-refresh on next use)" }
  end

  local minutes = math.floor((creds.expires - os.time()) / 60)
  return {
    authenticated = true,
    provider = PROVIDER_NAME,
    message = string.format("Authenticated (token expires in %d min)", minutes),
  }
end

--- Obtain a valid token (cached → refresh → full login) then call back with
--- (endpoint, headers) ready for a chat/completions POST.
---@param _model_id string
---@param callback fun(endpoint: string|nil, headers: table|nil, err: string|nil)
function M.prepare_request(_model_id, callback)
  local function make_result(creds)
    local base_url = get_base_url(creds.access_token, creds.enterprise_domain)
    local endpoint = base_url .. "/chat/completions"
    local headers = vim.tbl_extend("force", {
      content_type = "application/json",
      authorization = "Bearer " .. creds.access_token,
    }, COPILOT_HEADERS)
    callback(endpoint, headers)
  end

  local creds = store.read(PROVIDER_NAME)

  -- 1. Cached token is still valid
  if creds and not needs_refresh(creds) then
    make_result(creds)
    return
  end

  -- 2. Try to refresh using stored OAuth token
  if creds and creds.refresh_token then
    exchange_for_copilot_token(creds.refresh_token, creds.enterprise_domain, function(new_creds, err)
      if new_creds then
        make_result(new_creds)
      else
        vim.notify("Copilot token refresh failed: " .. (err or "unknown") .. ". Re-authenticating...", vim.log.levels.WARN)
        M.login(function(login_creds, login_err)
          if login_creds then
            make_result(login_creds)
          else
            callback(nil, nil, login_err or "Login failed")
          end
        end)
      end
    end)
    return
  end

  -- 3. No credentials at all – full login
  M.login(function(login_creds, login_err)
    if login_creds then
      make_result(login_creds)
    else
      callback(nil, nil, login_err or "Login failed")
    end
  end)
end

--- Return known models.
---@return AiProviderModel[]
function M.get_models()
  return models_data[PROVIDER_NAME] or {}
end

return M
