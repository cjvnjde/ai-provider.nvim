--- Model definitions for all supported providers.
--- Data sourced from pi-mono/packages/ai model registry.
local M = {}

---@class AiProviderModel
---@field id string Model ID used in API calls
---@field name string Human-readable display name
---@field provider string Provider this model belongs to
---@field context_window number Context window in tokens
---@field max_tokens number Maximum output tokens

--- GitHub Copilot models (all cost $0 – included in Copilot subscription).
---@type AiProviderModel[]
M["github-copilot"] = {
  { id = "claude-haiku-4.5", name = "Claude Haiku 4.5", provider = "github-copilot", context_window = 144000, max_tokens = 32000 },
  { id = "claude-opus-4.5", name = "Claude Opus 4.5", provider = "github-copilot", context_window = 160000, max_tokens = 32000 },
  { id = "claude-opus-4.6", name = "Claude Opus 4.6", provider = "github-copilot", context_window = 1000000, max_tokens = 64000 },
  { id = "claude-sonnet-4", name = "Claude Sonnet 4", provider = "github-copilot", context_window = 216000, max_tokens = 16000 },
  { id = "claude-sonnet-4.5", name = "Claude Sonnet 4.5", provider = "github-copilot", context_window = 144000, max_tokens = 32000 },
  { id = "claude-sonnet-4.6", name = "Claude Sonnet 4.6", provider = "github-copilot", context_window = 1000000, max_tokens = 32000 },
  { id = "gemini-2.5-pro", name = "Gemini 2.5 Pro", provider = "github-copilot", context_window = 128000, max_tokens = 64000 },
  { id = "gemini-3-flash-preview", name = "Gemini 3 Flash", provider = "github-copilot", context_window = 128000, max_tokens = 64000 },
  { id = "gemini-3-pro-preview", name = "Gemini 3 Pro Preview", provider = "github-copilot", context_window = 128000, max_tokens = 64000 },
  { id = "gemini-3.1-pro-preview", name = "Gemini 3.1 Pro Preview", provider = "github-copilot", context_window = 128000, max_tokens = 64000 },
  { id = "gpt-4.1", name = "GPT-4.1", provider = "github-copilot", context_window = 128000, max_tokens = 16384 },
  { id = "gpt-4o", name = "GPT-4o", provider = "github-copilot", context_window = 128000, max_tokens = 4096 },
  { id = "gpt-5", name = "GPT-5", provider = "github-copilot", context_window = 128000, max_tokens = 128000 },
  { id = "gpt-5-mini", name = "GPT-5 Mini", provider = "github-copilot", context_window = 264000, max_tokens = 64000 },
  { id = "gpt-5.1", name = "GPT-5.1", provider = "github-copilot", context_window = 264000, max_tokens = 64000 },
  { id = "gpt-5.1-codex", name = "GPT-5.1 Codex", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.1-codex-max", name = "GPT-5.1 Codex Max", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.1-codex-mini", name = "GPT-5.1 Codex Mini", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.2", name = "GPT-5.2", provider = "github-copilot", context_window = 264000, max_tokens = 64000 },
  { id = "gpt-5.2-codex", name = "GPT-5.2 Codex", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.3-codex", name = "GPT-5.3 Codex", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.4", name = "GPT-5.4", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "gpt-5.4-mini", name = "GPT-5.4 Mini", provider = "github-copilot", context_window = 400000, max_tokens = 128000 },
  { id = "grok-code-fast-1", name = "Grok Code Fast 1", provider = "github-copilot", context_window = 128000, max_tokens = 64000 },
}

--- OpenRouter models (curated popular selection).
--- Users can specify any model ID – this list is for discovery/UI only.
---@type AiProviderModel[]
M["openrouter"] = {
  -- Anthropic
  { id = "anthropic/claude-sonnet-4", name = "Claude Sonnet 4", provider = "openrouter", context_window = 200000, max_tokens = 16000 },
  { id = "anthropic/claude-sonnet-4.5", name = "Claude Sonnet 4.5", provider = "openrouter", context_window = 200000, max_tokens = 16000 },
  { id = "anthropic/claude-haiku-4.5", name = "Claude Haiku 4.5", provider = "openrouter", context_window = 200000, max_tokens = 8192 },
  { id = "anthropic/claude-opus-4", name = "Claude Opus 4", provider = "openrouter", context_window = 200000, max_tokens = 32000 },
  -- Google
  { id = "google/gemini-2.5-flash", name = "Gemini 2.5 Flash", provider = "openrouter", context_window = 1048576, max_tokens = 65536 },
  { id = "google/gemini-2.5-pro", name = "Gemini 2.5 Pro", provider = "openrouter", context_window = 1048576, max_tokens = 65536 },
  { id = "google/gemini-3-flash-preview", name = "Gemini 3 Flash Preview", provider = "openrouter", context_window = 1048576, max_tokens = 65536 },
  -- OpenAI
  { id = "openai/gpt-4o", name = "GPT-4o", provider = "openrouter", context_window = 128000, max_tokens = 16384 },
  { id = "openai/gpt-4.1", name = "GPT-4.1", provider = "openrouter", context_window = 128000, max_tokens = 32768 },
  { id = "openai/gpt-4.1-mini", name = "GPT-4.1 Mini", provider = "openrouter", context_window = 128000, max_tokens = 32768 },
  { id = "openai/gpt-4.1-nano", name = "GPT-4.1 Nano", provider = "openrouter", context_window = 128000, max_tokens = 32768 },
  { id = "openai/o3", name = "o3", provider = "openrouter", context_window = 200000, max_tokens = 100000 },
  { id = "openai/o4-mini", name = "o4-mini", provider = "openrouter", context_window = 200000, max_tokens = 100000 },
  -- DeepSeek
  { id = "deepseek/deepseek-chat-v3.1", name = "DeepSeek V3.1", provider = "openrouter", context_window = 65536, max_tokens = 8192 },
  { id = "deepseek/deepseek-r1", name = "DeepSeek R1", provider = "openrouter", context_window = 65536, max_tokens = 8192 },
  -- Mistral
  { id = "mistralai/mistral-large", name = "Mistral Large", provider = "openrouter", context_window = 128000, max_tokens = 32768 },
  { id = "mistralai/devstral-medium", name = "Devstral Medium", provider = "openrouter", context_window = 128000, max_tokens = 32768 },
  -- Meta
  { id = "meta-llama/llama-4-maverick", name = "Llama 4 Maverick", provider = "openrouter", context_window = 1048576, max_tokens = 65536 },
  { id = "meta-llama/llama-4-scout", name = "Llama 4 Scout", provider = "openrouter", context_window = 512000, max_tokens = 65536 },
  -- xAI
  { id = "x-ai/grok-4", name = "Grok 4", provider = "openrouter", context_window = 256000, max_tokens = 16384 },
  -- Qwen
  { id = "qwen/qwen3-coder", name = "Qwen3 Coder", provider = "openrouter", context_window = 262144, max_tokens = 65536 },
  { id = "qwen/qwen3-235b-a22b", name = "Qwen3 235B", provider = "openrouter", context_window = 131072, max_tokens = 40960 },
}

return M
