# ai-provider.nvim

A reusable AI provider abstraction for Neovim plugins. Handles authentication, model discovery, and HTTP requests for multiple AI providers.

## Supported Providers

| Provider | Auth | Description |
| --- | --- | --- |
| `openrouter` | API key | [OpenRouter](https://openrouter.ai) – access 200+ models with one key |
| `github-copilot` | OAuth | GitHub Copilot – uses your existing subscription, no separate key needed |

## Prerequisites

- Neovim >= 0.8.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {}, -- optional, see Configuration below
}
```

## Configuration

Setup is **optional** – sane defaults work out of the box.

```lua
require("ai-provider").setup({
  providers = {
    openrouter = {
      api_key = nil,                           -- falls back to OPENROUTER_API_KEY env var
      url = "https://openrouter.ai/api/v1/",   -- base URL
      chat_url = "chat/completions",            -- endpoint path
    },
    ["github-copilot"] = {
      enterprise_domain = nil,                  -- e.g. "company.ghe.com"
    },
  },
})
```

## API

### Setup

```lua
local ai = require("ai-provider")
ai.setup(opts)  -- optional
```

### Authentication

```lua
-- Login (triggers OAuth flow for Copilot, validates key for OpenRouter)
ai.login("github-copilot", function(result, err) end)

-- Logout (clears stored credentials)
ai.logout("github-copilot")

-- Check status
local status = ai.status("github-copilot")
-- { authenticated = true, provider = "github-copilot", message = "..." }
```

### Models

```lua
-- List available models for a provider
local models = ai.get_models("github-copilot")
-- { { id = "gpt-4o", name = "GPT-4o", provider = "github-copilot", ... }, ... }

-- List registered providers
local providers = ai.get_providers()
-- { "github-copilot", "openrouter" }
```

### Requests

```lua
-- Send a chat-completion request (handles auth automatically)
ai.request({
  provider = "github-copilot",
  model = "gpt-4o",
  body = {
    model = "gpt-4o",
    messages = {
      { role = "system", content = "You are a helpful assistant." },
      { role = "user", content = "Hello!" },
    },
    max_tokens = 1024,
  },
}, function(response, err)
  if err then
    print("Error: " .. err)
    return
  end
  -- response is the raw plenary.curl response: { status, body, headers }
  if response.status == 200 then
    local data = vim.json.decode(response.body)
    print(data.choices[1].message.content)
  end
end)
```

### Custom Providers

You can register your own provider:

```lua
ai.register_provider("my-provider", {
  prepare_request = function(model_id, callback)
    -- callback(endpoint, headers) on success
    -- callback(nil, nil, err_string) on failure
  end,
  login = function(callback) end,
  logout = function() end,
  status = function() return { authenticated = true, provider = "my-provider", message = "OK" } end,
  get_models = function() return {} end,
})
```

## Provider Details

### OpenRouter

Uses API key authentication. Set the key via:
- Environment variable: `export OPENROUTER_API_KEY=sk-...`
- Config: `{ providers = { openrouter = { api_key = "sk-..." } } }`

### GitHub Copilot

Uses GitHub's OAuth device-code flow (same as VS Code Copilot). On first use or `login()`, a browser opens for you to authorize. Tokens are cached and auto-refreshed.

**GitHub Enterprise:** Set `enterprise_domain` in the provider config.

**Available models:** `gpt-4o`, `gpt-4.1`, `claude-sonnet-4`, `claude-haiku-4.5`, `gemini-2.5-pro`, `grok-code-fast-1`, and more. Run `get_models("github-copilot")` for the full list.
