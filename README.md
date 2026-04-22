# ai-provider.nvim

A reusable AI provider abstraction for Neovim plugins based on the [pi.dev](https://github.com/badlogic/pi-mono) providers.

`ai-provider.nvim` is a shared foundation layer that other plugins (like `ai-commit.nvim` and `ai-split-commit.nvim`) use to talk to AI models. It handles authentication, model discovery, SSE streaming, and unified reasoning configuration across multiple AI providers — so consumer plugins don't have to deal with any of that themselves.

You typically don't interact with `ai-provider.nvim` directly. It is pulled in as a dependency and can be configured through a consumer plugin's `ai_provider` passthrough option (for example from `ai-commit.nvim` or `ai-split-commit.nvim`). However, you can also use it standalone for your own scripting or plugin development.

## Supported Providers

The plugin implements **ten** of pi-mono's API wire protocols natively,
and surfaces every provider from pi-mono's catalog (including providers
whose APIs aren't fully implemented — those will error clearly when
called).

| Provider | API | Auth | Reasoning | Env Variable |
|----------|-----|------|-----------|--------------|
| **Anthropic** | `anthropic-messages` | API key / sk-ant-oat OAuth | Budget + adaptive thinking (incl. `xhigh` on Opus 4.6/4.7) | `ANTHROPIC_API_KEY` / `ANTHROPIC_OAUTH_TOKEN` |
| **Google Gemini** | `google-generative-ai` | API key | Budget (2.5) & level-based (3.x) | `GEMINI_API_KEY` |
| **OpenAI** | `openai-responses` | API key | `reasoning_effort` (incl. `xhigh` on GPT-5.2/5.3/5.4) | `OPENAI_API_KEY` |
| **Azure OpenAI** | `azure-openai-responses` | `api-key` header | `reasoning_effort` | `AZURE_OPENAI_API_KEY` |
| **OpenRouter** | `openai-completions` | API key | OpenRouter `reasoning.effort` + anthropic cache_control for `anthropic/*` | `OPENROUTER_API_KEY` |
| **GitHub Copilot** | `anthropic-messages` / `openai-completions` / `openai-responses` | OAuth device-code flow | Per-model | OAuth (no env needed) |
| **xAI** | `openai-completions` | API key | — | `XAI_API_KEY` |
| **Groq** | `openai-completions` | API key | `reasoning_effort` | `GROQ_API_KEY` |
| **Cerebras** | `openai-completions` | API key | — | `CEREBRAS_API_KEY` |
| **z.ai** | `openai-completions` | API key | top-level `enable_thinking` | `ZAI_API_KEY` |
| **Mistral** | `mistral-conversations` | API key | `prompt_mode:"reasoning"` or `reasoning_effort:"high"` | `MISTRAL_API_KEY` |
| **DeepSeek / Fireworks / HuggingFace / Minimax / Opencode / Kimi / Qwen / Vercel AI Gateway** | `openai-completions` | API key | varies (`openrouter`, `zai`, `qwen`, `qwen-chat-template`, `openai`) | see below |

**Not implemented (stubbed with clear error):**

| Provider / API | Why | Workaround |
|----------|-----|-----------|
| `amazon-bedrock` / `bedrock-converse-stream` | AWS SigV4 request signing + Bedrock event framing are out of scope. | Proxy through an OpenAI-compatible gateway (e.g. Vercel AI Gateway, LiteLLM). |
| `google-gemini-cli` | Requires the `gemini` CLI's OAuth token store + CloudCode endpoint. | Use the `google` provider with `GEMINI_API_KEY`. |
| `google-vertex` (ADC path) | Requires RS256-signed service-account JWT exchange. | Set `GOOGLE_CLOUD_API_KEY` to use a plain API key — the plugin delegates to `google-generative-ai` in that case. |
| `openai-codex-responses` | Requires Codex (ChatGPT account) OAuth device-code flow. | Pass a pre-obtained access token via `options.api_key`; the plugin then delegates to `openai-responses`. |

Env variables honored (in addition to those in the table above):
`AZURE_OPENAI_API_KEY`, `AI_GATEWAY_API_KEY`, `ZAI_API_KEY`,
`MINIMAX_API_KEY`, `MINIMAX_CN_API_KEY`, `HF_TOKEN`, `FIREWORKS_API_KEY`,
`OPENCODE_API_KEY`, `KIMI_API_KEY`, `DEEPSEEK_API_KEY`,
`GOOGLE_CLOUD_API_KEY`.

---

## Requirements

- Neovim >= 0.8.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (for legacy `request()` and Copilot OAuth)
- `curl` (system binary, for streaming)

---

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
}
```

---

## Setup

```lua
require("ai-provider").setup(opts)
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `providers` | `table<string, table>` | `{}` | Provider-specific settings. Each key is a provider name, each value is a table with settings like `api_key`, `enterprise_domain`, etc. |
| `reasoning` | `string?` | `nil` | Default reasoning level for `stream_simple()`. One of `"minimal"`, `"low"`, `"medium"`, `"high"`. When `nil`, reasoning is disabled by default. |
| `debug` | `boolean` | `false` | Save one JSON debug dump per request to `~/.cache/nvim/ai-provider-debug/`, including request context/options and final response or error. |
| `notification` | `table` | `{ enabled = true }` | Top-right sending notification configuration. Set `notification.enabled = false` to disable the request spinner popup. |
| `debug_toast` | `table` | `{ enabled = false, max_width = 60, max_height = 15, dismiss_delay = 3000 }` | Bottom-right streaming debug toast configuration. Useful when inspecting streamed text, reasoning blocks, tool calls, and token usage. |
| `custom_models` | `table?` | `nil` | Custom model definitions keyed by provider name. Each value is a list of model definition tables. If a custom model uses the same `id` as an existing model for that provider, it extends/overrides the built-in entry instead of creating a duplicate. |

When `ai-provider.nvim` is used through consumer plugins, this exact table is passed as:

```lua
opts = {
  ai_provider = {
    -- same fields as ai-provider.setup(...)
  },
}
```

### Provider-specific settings

Each provider entry in `providers` accepts:

| Provider | Settings |
|----------|----------|
| `openrouter` | `api_key` (string) — overrides `OPENROUTER_API_KEY` env var |
| `anthropic` | `api_key` (string) — overrides `ANTHROPIC_API_KEY` env var |
| `google` | `api_key` (string) — overrides `GEMINI_API_KEY` env var |
| `openai` | `api_key` (string) — overrides `OPENAI_API_KEY` env var |
| `github-copilot` | `enterprise_domain` (string) — for GitHub Enterprise (e.g., `"company.ghe.com"`) |
| `xai` | `api_key` (string) — overrides `XAI_API_KEY` env var |
| `groq` | `api_key` (string) — overrides `GROQ_API_KEY` env var |
| `cerebras` | `api_key` (string) — overrides `CEREBRAS_API_KEY` env var |
| `mistral` | `api_key` (string) — overrides `MISTRAL_API_KEY` env var |

---

## Consumer plugin passthrough examples

In most setups you configure `ai-provider.nvim` indirectly through `ai-commit.nvim` or `ai-split-commit.nvim`.

### Via `ai-commit.nvim`

```lua
{
  "cjvnjde/ai-commit.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    "cjvnjde/ai-provider.nvim",
  },
  opts = {
    provider = "github-copilot",
    model = "gpt-5-mini",
    ai_options = {
      reasoning = "high",
    },
    ai_provider = {
      debug = true,
      debug_toast = { enabled = true },
      providers = {
        ["github-copilot"] = {
          enterprise_domain = "company.ghe.com",
        },
      },
    },
  },
}
```

### Via `ai-split-commit.nvim`

```lua
{
  "cjvnjde/ai-split-commit.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "cjvnjde/ai-provider.nvim",
    "cjvnjde/ai-commit.nvim",
  },
  opts = {
    provider = "openrouter",
    model = "google/gemini-2.5-pro",
    ai_options = {
      reasoning = "high",
    },
    ai_provider = {
      notification = { enabled = true },
      providers = {
        openrouter = { api_key = "sk-or-..." },
      },
    },
  },
}
```

---

## Configuration Examples

### 1. Minimal — use environment variables only

Set your API keys in your shell profile and don't pass anything to `setup()`:

```bash
export OPENROUTER_API_KEY=sk-or-...
export ANTHROPIC_API_KEY=sk-ant-...
export GEMINI_API_KEY=AIza...
```

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
}
```

### 2. OpenRouter with explicit API key

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    providers = {
      openrouter = { api_key = "sk-or-your-key-here" },
    },
  },
}
```

### 3. Multiple providers configured at once

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    providers = {
      openrouter = { api_key = "sk-or-..." },
      anthropic  = { api_key = "sk-ant-..." },
      google     = { api_key = "AIza..." },
    },
    reasoning = "medium",
  },
}
```

### 4. GitHub Copilot (free with Copilot subscription)

No API key needed — uses OAuth device-code flow:

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
}
```

Then authenticate once:

```vim
:lua require("ai-provider").login("github-copilot")
```

### 5. GitHub Copilot with Enterprise

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    providers = {
      ["github-copilot"] = {
        enterprise_domain = "company.ghe.com",
      },
    },
  },
}
```

### 6. Custom models

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
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
  },
}
```

If a custom model reuses an existing provider + `id`, the built-in entry is updated/extended instead of duplicated.

### 7. Default reasoning level

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    reasoning = "high",
    providers = {
      anthropic = { api_key = "sk-ant-..." },
    },
  },
}
```

### 8. Debug dumps + streaming debug toast

```lua
{
  "cjvnjde/ai-provider.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    reasoning = "high",
    debug = true,
    notification = { enabled = true },
    debug_toast = {
      enabled = true,
      max_width = 50,
      max_height = 12,
      dismiss_delay = 5000,
    },
  },
}
```

This saves JSON request/response logs under `~/.cache/nvim/ai-provider-debug/` and shows a bottom-right streaming debug toast while requests are active.

---

## Streaming API

The core API uses **SSE streaming** with an event callback pattern:

```lua
local ai = require("ai-provider")

local model = ai.get_model("openrouter", "anthropic/claude-sonnet-4")

local es = ai.stream_simple(model, {
  system_prompt = "You are a helpful assistant.",
  messages = {
    { role = "user", content = "Explain monads in 3 sentences." },
  },
}, { reasoning = "medium" })

es:on(function(event)
  if event.type == "text_delta" then
    io.write(event.delta)
  elseif event.type == "thinking_delta" then
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

-- Cancel if needed:
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
| `"xhigh"` | Opus 4.6 → `max`, Opus 4.7 → `xhigh` (adaptive) | clamped to `high` | GPT-5.2/5.3/5.4 native; otherwise clamped to `high` |

---

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

---

## Non-Streaming Convenience

```lua
ai.complete_simple(model, context, { reasoning = "high" }, function(msg)
  print(msg.content[1].text)
end)
```

---

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

---

## GitHub Copilot Authentication

```lua
ai.login("github-copilot")   -- starts OAuth device-code flow
ai.status("github-copilot")  -- check auth status
ai.logout("github-copilot")  -- clear credentials

-- Then use Copilot models (free with Copilot subscription)
local model = ai.get_model("github-copilot", "claude-sonnet-4.6")
local es = ai.stream_simple(model, context, { reasoning = "high" })
```

---

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
