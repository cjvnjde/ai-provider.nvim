# ai-provider.nvim

Reusable AI provider abstraction for Neovim plugins. Handles authentication,
model discovery, SSE streaming, and unified reasoning configuration across
multiple AI providers.

## Supported Providers

| Provider | API | Auth | Reasoning |
|----------|-----|------|-----------|
| **Anthropic** | `anthropic-messages` | API key (`ANTHROPIC_API_KEY`) | Budget & adaptive thinking |
| **Google Gemini** | `google-generative-ai` | API key (`GEMINI_API_KEY`) | Budget & level-based thinking |
| **OpenAI** | `openai-completions` | API key (`OPENAI_API_KEY`) | `reasoning_effort` |
| **OpenRouter** | `openai-completions` | API key (`OPENROUTER_API_KEY`) | OpenRouter reasoning format |
| **GitHub Copilot** | Both | OAuth device-code flow | Per-model |
| **xAI** | `openai-completions` | API key (`XAI_API_KEY`) | ✓ |
| **Groq** | `openai-completions` | API key (`GROQ_API_KEY`) | ✓ |
| **Cerebras** | `openai-completions` | API key (`CEREBRAS_API_KEY`) | — |
| **Mistral** | `openai-completions` | API key (`MISTRAL_API_KEY`) | — |

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" }, -- for legacy request() and Copilot OAuth
}
```

## Setup

```lua
require("ai-provider").setup({
  providers = {
    openrouter = { api_key = "sk-or-..." },
    anthropic  = { api_key = "sk-ant-..." },
    google     = { api_key = "AIza..." },
    -- or set environment variables: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, etc.
  },
  reasoning = "medium",  -- default reasoning level (optional)
})
```

## Streaming API

The core API uses **SSE streaming** with an event callback pattern:

```lua
local ai = require("ai-provider")

-- Get a model
local model = ai.get_model("openrouter", "anthropic/claude-sonnet-4")

-- Stream with unified reasoning
local es = ai.stream_simple(model, {
  system_prompt = "You are a helpful assistant.",
  messages = {
    { role = "user", content = "Explain monads in 3 sentences." },
  },
}, { reasoning = "medium" })

-- Subscribe to events
es:on(function(event)
  if event.type == "text_delta" then
    io.write(event.delta)
  elseif event.type == "thinking_delta" then
    -- reasoning/thinking content
    io.write("[think] " .. event.delta)
  end
end)

es:on_done(function(msg)
  print("\n--- Done ---")
  print("Model:", msg.model)
  print("Tokens:", msg.usage.total_tokens)
  print("Cost: $" .. string.format("%.6f", msg.usage.cost.total))
end)

es:on_error(function(msg)
  print("Error:", msg.error_message)
end)

-- Cancel if needed
-- es:stop()
```

### Event Types

| Event | Fields | Description |
|-------|--------|-------------|
| `start` | `partial` | Stream started |
| `text_start` | `content_index`, `partial` | New text block |
| `text_delta` | `content_index`, `delta`, `partial` | Text chunk |
| `text_end` | `content_index`, `content`, `partial` | Text block complete |
| `thinking_start` | `content_index`, `partial` | Reasoning started |
| `thinking_delta` | `content_index`, `delta`, `partial` | Reasoning chunk |
| `thinking_end` | `content_index`, `content`, `partial` | Reasoning complete |
| `toolcall_start` | `content_index`, `partial` | Tool call started |
| `toolcall_delta` | `content_index`, `delta`, `partial` | Tool call args chunk |
| `toolcall_end` | `content_index`, `tool_call`, `partial` | Tool call complete |
| `done` | `reason`, `message` | Success |
| `error` | `reason`, `error` | Failure |

### Reasoning Levels

Unified across all providers:

| Level | Anthropic | Google | OpenAI/OpenRouter |
|-------|-----------|--------|-------------------|
| `"minimal"` | Low effort / 1024 budget | Minimal / 128 budget | `"minimal"` |
| `"low"` | Low effort / 2048 budget | Low / 2048 budget | `"low"` |
| `"medium"` | Medium effort / 8192 budget | Medium / 8192 budget | `"medium"` |
| `"high"` | High effort / 16384 budget | High / 32768 budget | `"high"` |

## Provider-Specific Streaming

For fine-grained control, use `stream()` instead of `stream_simple()`:

```lua
-- Anthropic with explicit thinking config
local es = ai.stream(model, context, {
  thinking_enabled = true,
  thinking_budget_tokens = 16384,
  max_tokens = 32000,
})

-- OpenAI with explicit reasoning effort
local es = ai.stream(model, context, {
  reasoning_effort = "high",
  max_tokens = 32000,
})

-- Google with thinking level
local es = ai.stream(model, context, {
  thinking = { enabled = true, level = "HIGH" },
  max_tokens = 32000,
})
```

## Non-Streaming Convenience

```lua
ai.complete_simple(model, context, { reasoning = "high" }, function(msg)
  print(msg.content[1].text)
end)
```

## Model Discovery

```lua
-- List all providers
local providers = ai.get_providers()

-- List models for a provider
local models = ai.get_models("anthropic")
for _, m in ipairs(models) do
  print(m.id, m.name, m.reasoning and "🧠" or "")
end

-- Get a specific model
local model = ai.get_model("google", "gemini-2.5-pro")
print(model.context_window, model.max_tokens, model.cost.input)
```

## GitHub Copilot Authentication

```lua
ai.login("github-copilot")   -- starts OAuth device-code flow
ai.status("github-copilot")  -- check auth status
ai.logout("github-copilot")  -- clear credentials

-- Then use Copilot models (free with Copilot subscription)
local model = ai.get_model("github-copilot", "claude-sonnet-4.6")
local es = ai.stream_simple(model, context, { reasoning = "high" })
```

## Custom Models

```lua
ai.setup({
  custom_models = {
    ["my-provider"] = {
      {
        id = "my-model",
        name = "My Custom Model",
        api = "openai-completions",
        provider = "my-provider",
        base_url = "https://my-api.example.com/v1",
        reasoning = false,
        input = { "text" },
        cost = { input = 1, output = 2, cache_read = 0, cache_write = 0 },
        context_window = 128000,
        max_tokens = 8192,
      },
    },
  },
})
```

## Custom API Providers

Register a custom streaming implementation:

```lua
ai.register_api("my-custom-api", {
  stream = function(model, context, options)
    local es = require("ai-provider.event_stream").new()
    -- ... implement streaming ...
    return es
  end,
  stream_simple = function(model, context, options)
    -- ... map reasoning level to provider-specific params ...
  end,
})
```

## Legacy API (backward compatible)

The original `request()` API still works:

```lua
ai.request({
  provider = "openrouter",
  model = "anthropic/claude-sonnet-4",
  body = {
    model = "anthropic/claude-sonnet-4",
    messages = {{ role = "user", content = "Hello!" }},
    max_tokens = 1000,
  },
}, function(response, err)
  if err then print("Error:", err) return end
  local data = vim.json.decode(response.body)
  print(data.choices[1].message.content)
end)
```

## Architecture

```
ai-provider/
├── init.lua                 -- Top-level API
├── config.lua               -- Configuration store
├── types.lua                -- Type constants & constructors
├── models.lua               -- Rich model definitions (all providers)
├── stream.lua               -- stream() / complete() / stream_simple()
├── event_stream.lua         -- EventStream class
├── sse.lua                  -- SSE parser
├── curl_stream.lua          -- Shared curl streaming utility
├── env_keys.lua             -- Environment API key resolution
├── api_registry.lua         -- API provider registry (by API type)
├── credential_store.lua     -- Persistent OAuth credential storage
├── request.lua              -- Legacy HTTP request helper
└── providers/
    ├── init.lua             -- Registers built-in providers
    ├── openai_completions.lua  -- OpenAI Chat Completions streaming
    ├── anthropic.lua        -- Anthropic Messages streaming
    ├── google.lua           -- Google Generative AI streaming
    ├── copilot.lua          -- GitHub Copilot OAuth
    └── openrouter.lua       -- OpenRouter auth helper
```
