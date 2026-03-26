# ai-provider.nvim

A reusable AI provider layer for Neovim plugins.

`ai-provider.nvim` is the shared transport/auth/model-discovery plugin used by:
- [ai-commit.nvim](https://github.com/cjvnjde/ai-commit.nvim)
- [ai-split-commit.nvim](https://github.com/cjvnjde/ai-split-commit.nvim)
- your own custom plugins

It handles:
- provider setup
- authentication
- model discovery
- HTTP requests
- request logging

## Supported providers

| Provider | Auth | Notes |
| --- | --- | --- |
| `openrouter` | API key | One key, many models |
| `github-copilot` | OAuth | Uses your Copilot subscription |

## Features

- shared provider abstraction for multiple plugins
- OpenRouter and GitHub Copilot support
- model browser support via consumer plugins
- authentication helpers
- custom provider registration
- request logging with provider + model + host

Example request notification:

```text
Sending AI request: AICommit -> github-copilot / gpt-5-mini -> api.githubcopilot.com
```

---

## Installation

### lazy.nvim

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  opts = {},
}
```

Setup is optional.

---

## Quick start

### OpenRouter

```bash
export OPENROUTER_API_KEY=sk-...
```

```lua
require("ai-provider").setup({
  providers = {
    openrouter = {
      api_key = nil, -- uses OPENROUTER_API_KEY if nil
    },
  },
})
```

### GitHub Copilot

```lua
require("ai-provider").setup({
  providers = {
    ["github-copilot"] = {},
  },
})
```

Then authenticate once:

```vim
:lua require("ai-provider").login("github-copilot")
```

---

## Configuration

```lua
require("ai-provider").setup({
  providers = {
    openrouter = {
      api_key = nil,
      url = "https://openrouter.ai/api/v1/",
      chat_url = "chat/completions",
    },
    ["github-copilot"] = {
      enterprise_domain = nil,
    },
  },
})
```

### Config reference

| Key | Type | Description |
| --- | --- | --- |
| `providers.openrouter.api_key` | `string?` | OpenRouter API key |
| `providers.openrouter.url` | `string?` | Override OpenRouter base URL |
| `providers.openrouter.chat_url` | `string?` | Override chat endpoint path |
| `providers["github-copilot"].enterprise_domain` | `string?` | GitHub Enterprise domain |

---

## API

## Setup

```lua
local ai = require("ai-provider")
ai.setup(opts)
```

## Authentication

```lua
local ai = require("ai-provider")

ai.login("github-copilot", function(result, err)
  if result then
    print("ok")
  else
    print(err)
  end
end)

ai.logout("github-copilot")

local status = ai.status("github-copilot")
-- {
--   authenticated = true,
--   provider = "github-copilot",
--   message = "Authenticated"
-- }
```

## Models

```lua
local ai = require("ai-provider")

local models = ai.get_models("github-copilot")
local providers = ai.get_providers()
```

## Requests

```lua
local ai = require("ai-provider")

ai.request({
  provider = "github-copilot",
  model = "gpt-5-mini",
  label = "Example",
  body = {
    model = "gpt-5-mini",
    messages = {
      { role = "system", content = "You are helpful." },
      { role = "user", content = "Say hello" },
    },
    max_tokens = 128,
  },
}, function(response, err)
  if err then
    print(err)
    return
  end

  if response.status == 200 then
    local data = vim.json.decode(response.body)
    print(data.choices[1].message.content)
  end
end)
```

### Request logging

`label` is optional but useful for logs:

```lua
label = "AICommit"
label = "AISplitCommit[grouping]"
label = "MyPlugin"
```

This produces notifications like:

```text
Sending AI request: AISplitCommit[grouping] -> github-copilot / gpt-5-mini -> api.githubcopilot.com
```

---

## Custom providers

```lua
require("ai-provider").register_provider("my-provider", {
  prepare_request = function(model_id, callback)
    -- callback(endpoint, headers)
    -- or callback(nil, nil, err)
  end,
  login = function(callback) end,
  logout = function() end,
  status = function()
    return {
      authenticated = true,
      provider = "my-provider",
      message = "OK",
    }
  end,
  get_models = function()
    return {}
  end,
})
```

---

## Usage examples

## 1. Shared config for multiple plugins

If both `ai-commit.nvim` and `ai-split-commit.nvim` use the same provider, you can configure the provider once:

```lua
{
  "cjvnjde/ai-provider.nvim",
  opts = {
    providers = {
      ["github-copilot"] = {},
    },
  },
}
```

Then each consumer plugin can just say:

```lua
opts = {
  provider = "github-copilot",
  model = "gpt-5-mini",
}
```

## 2. Forward provider config through a consumer plugin

Both `ai-commit.nvim` and `ai-split-commit.nvim` support:

```lua
provider_config = {
  ["github-copilot"] = {
    enterprise_domain = "company.ghe.com",
  },
}
```

So you can keep provider config close to the consumer plugin.

## 3. GitHub Enterprise

```lua
require("ai-provider").setup({
  providers = {
    ["github-copilot"] = {
      enterprise_domain = "company.ghe.com",
    },
  },
})
```

## 4. Local development setup

```lua
{
  dir = "/mnt/shared/projects/personal/nvim-plugins/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
}
```

---

## Notes

- `ai-provider.nvim` does not decide prompts or UI.
- Consumer plugins build prompts and pass the request body.
- Request notifications now show:
  - source label
  - provider
  - model
  - destination host
