--- Model definitions for all supported providers.
---
--- Each model contains:
---   id, name, api, provider, base_url, reasoning, input,
---   cost { input, output, cache_read, cache_write },
---   context_window, max_tokens,
---   headers? (static headers), compat? (API compat overrides)
---
--- Data sourced from pi-mono packages/ai/src/models.generated.ts.
local M = {}

---------------------------------------------------------------------------
-- Copilot static headers
---------------------------------------------------------------------------

local COPILOT_HEADERS = {
  ["User-Agent"]              = "GitHubCopilotChat/0.35.0",
  ["Editor-Version"]          = "vscode/1.107.0",
  ["Editor-Plugin-Version"]   = "copilot-chat/0.35.0",
  ["Copilot-Integration-Id"]  = "vscode-chat",
}

local COPILOT_COMPAT_NO_STANDARD = {
  supports_store = false,
  supports_developer_role = false,
  supports_reasoning_effort = false,
}

local COPILOT_URL = "https://api.individual.githubcopilot.com"

---------------------------------------------------------------------------
-- Helper to build a model entry
---------------------------------------------------------------------------

local function m(t)
  t.input = t.input or { "text" }
  t.cost = t.cost or { input = 0, output = 0, cache_read = 0, cache_write = 0 }
  return t
end

---------------------------------------------------------------------------
-- Anthropic direct
---------------------------------------------------------------------------

M["anthropic"] = {
  m { id = "claude-3-5-haiku-20241022",  name = "Claude Haiku 3.5",  api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = false, input = { "text", "image" }, cost = { input = 0.8, output = 4, cache_read = 0.08, cache_write = 1 }, context_window = 200000, max_tokens = 8192 },
  m { id = "claude-3-7-sonnet-20250219", name = "Claude Sonnet 3.7", api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 200000, max_tokens = 64000 },
  m { id = "claude-sonnet-4-20250514",   name = "Claude Sonnet 4",   api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 200000, max_tokens = 64000 },
  m { id = "claude-sonnet-4-5-20250514", name = "Claude Sonnet 4.5", api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 200000, max_tokens = 64000 },
  m { id = "claude-opus-4-5-20250805",   name = "Claude Opus 4.5",   api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 15, output = 75, cache_read = 1.5, cache_write = 18.75 }, context_window = 200000, max_tokens = 32000 },
  m { id = "claude-opus-4-6-20250805",   name = "Claude Opus 4.6",   api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 15, output = 75, cache_read = 1.5, cache_write = 18.75 }, context_window = 1000000, max_tokens = 64000 },
  m { id = "claude-sonnet-4-6-20250805", name = "Claude Sonnet 4.6", api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 1000000, max_tokens = 64000 },
  m { id = "claude-haiku-4-5-20251001",  name = "Claude Haiku 4.5",  api = "anthropic-messages", provider = "anthropic", base_url = "https://api.anthropic.com", reasoning = true,  input = { "text", "image" }, cost = { input = 1, output = 5, cache_read = 0.1, cache_write = 1.25 }, context_window = 200000, max_tokens = 64000 },
}

---------------------------------------------------------------------------
-- Google (Gemini direct)
---------------------------------------------------------------------------

M["google"] = {
  m { id = "gemini-2.0-flash",      name = "Gemini 2.0 Flash",      api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = false, input = { "text", "image" }, cost = { input = 0.1, output = 0.4, cache_read = 0.025, cache_write = 0 }, context_window = 1048576, max_tokens = 8192 },
  m { id = "gemini-2.0-flash-lite", name = "Gemini 2.0 Flash Lite", api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = false, input = { "text", "image" }, cost = { input = 0.075, output = 0.3, cache_read = 0, cache_write = 0 }, context_window = 1048576, max_tokens = 8192 },
  m { id = "gemini-2.5-flash",      name = "Gemini 2.5 Flash",      api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = true,  input = { "text", "image" }, cost = { input = 0.3, output = 2.5, cache_read = 0.075, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "gemini-2.5-pro",        name = "Gemini 2.5 Pro",        api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = true,  input = { "text", "image" }, cost = { input = 2.5, output = 15, cache_read = 0.625, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "gemini-3-flash-preview",name = "Gemini 3 Flash Preview",api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = true,  input = { "text", "image" }, cost = { input = 0.6, output = 3.5, cache_read = 0, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "gemini-3-pro-preview",  name = "Gemini 3 Pro Preview",  api = "google-generative-ai", provider = "google", base_url = "https://generativelanguage.googleapis.com/v1beta", reasoning = true,  input = { "text", "image" }, cost = { input = 2.5, output = 15, cache_read = 0, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
}

---------------------------------------------------------------------------
-- OpenAI direct
---------------------------------------------------------------------------

M["openai"] = {
  m { id = "gpt-4o",          name = "GPT-4o",          api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = false, input = { "text", "image" }, cost = { input = 2.5, output = 10, cache_read = 1.25, cache_write = 0 }, context_window = 128000, max_tokens = 16384 },
  m { id = "gpt-4.1",         name = "GPT-4.1",         api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = false, input = { "text", "image" }, cost = { input = 2, output = 8, cache_read = 0.5, cache_write = 0 }, context_window = 1047576, max_tokens = 32768 },
  m { id = "gpt-4.1-mini",    name = "GPT-4.1 Mini",    api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = false, input = { "text", "image" }, cost = { input = 0.4, output = 1.6, cache_read = 0.1, cache_write = 0 }, context_window = 1047576, max_tokens = 32768 },
  m { id = "gpt-4.1-nano",    name = "GPT-4.1 Nano",    api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = false, input = { "text", "image" }, cost = { input = 0.1, output = 0.4, cache_read = 0.03, cache_write = 0 }, context_window = 1047576, max_tokens = 32768 },
  m { id = "o3",               name = "o3",              api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = true,  input = { "text", "image" }, cost = { input = 2, output = 8, cache_read = 0.5, cache_write = 0 }, context_window = 200000, max_tokens = 100000 },
  m { id = "o4-mini",          name = "o4-mini",         api = "openai-completions", provider = "openai", base_url = "https://api.openai.com/v1", reasoning = true,  input = { "text", "image" }, cost = { input = 1.1, output = 4.4, cache_read = 0.275, cache_write = 0 }, context_window = 200000, max_tokens = 100000 },
}

---------------------------------------------------------------------------
-- GitHub Copilot (Claude models → anthropic-messages, GPT/Gemini → openai-completions)
---------------------------------------------------------------------------

M["github-copilot"] = {
  -- Claude models (anthropic-messages API)
  m { id = "claude-haiku-4.5",     name = "Claude Haiku 4.5",     api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 144000, max_tokens = 32000 },
  m { id = "claude-opus-4.5",      name = "Claude Opus 4.5",      api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 160000, max_tokens = 32000 },
  m { id = "claude-opus-4.6",      name = "Claude Opus 4.6",      api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 1000000, max_tokens = 64000 },
  m { id = "claude-sonnet-4",      name = "Claude Sonnet 4",      api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 216000, max_tokens = 16000 },
  m { id = "claude-sonnet-4.5",    name = "Claude Sonnet 4.5",    api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 144000, max_tokens = 32000 },
  m { id = "claude-sonnet-4.6",    name = "Claude Sonnet 4.6",    api = "anthropic-messages", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, reasoning = true,  input = { "text", "image" }, context_window = 1000000, max_tokens = 32000 },
  -- GPT / Gemini models (openai-completions API)
  m { id = "gemini-2.5-pro",        name = "Gemini 2.5 Pro",        api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = false, input = { "text", "image" }, context_window = 128000, max_tokens = 64000 },
  m { id = "gemini-3-flash-preview",name = "Gemini 3 Flash",        api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 128000, max_tokens = 64000 },
  m { id = "gemini-3-pro-preview",  name = "Gemini 3 Pro Preview",  api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 128000, max_tokens = 64000 },
  m { id = "gemini-3.1-pro-preview",name = "Gemini 3.1 Pro Preview",api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 128000, max_tokens = 64000 },
  m { id = "gpt-4.1",               name = "GPT-4.1",               api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = false, input = { "text", "image" }, context_window = 128000, max_tokens = 16384 },
  m { id = "gpt-4o",                name = "GPT-4o",                api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = false, input = { "text", "image" }, context_window = 128000, max_tokens = 4096 },
  m { id = "gpt-5",                 name = "GPT-5",                 api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 128000, max_tokens = 128000 },
  m { id = "gpt-5-mini",            name = "GPT-5 Mini",            api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 264000, max_tokens = 64000 },
  m { id = "gpt-5.1",               name = "GPT-5.1",               api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 264000, max_tokens = 64000 },
  m { id = "gpt-5.2",               name = "GPT-5.2",               api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = true,  input = { "text", "image" }, context_window = 264000, max_tokens = 64000 },
  m { id = "grok-code-fast-1",      name = "Grok Code Fast 1",      api = "openai-completions", provider = "github-copilot", base_url = COPILOT_URL, headers = COPILOT_HEADERS, compat = COPILOT_COMPAT_NO_STANDARD, reasoning = false, input = { "text" },          context_window = 128000, max_tokens = 64000 },
}

---------------------------------------------------------------------------
-- OpenRouter (all models use openai-completions API)
---------------------------------------------------------------------------

local OR_URL = "https://openrouter.ai/api/v1"

M["openrouter"] = {
  -- Anthropic
  m { id = "anthropic/claude-sonnet-4",   name = "Claude Sonnet 4",   api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 200000, max_tokens = 16000 },
  m { id = "anthropic/claude-sonnet-4.5", name = "Claude Sonnet 4.5", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 200000, max_tokens = 16000 },
  m { id = "anthropic/claude-haiku-4.5",  name = "Claude Haiku 4.5",  api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 1, output = 5, cache_read = 0.1, cache_write = 1.25 }, context_window = 200000, max_tokens = 8192 },
  m { id = "anthropic/claude-opus-4",     name = "Claude Opus 4",     api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 15, output = 75, cache_read = 1.5, cache_write = 18.75 }, context_window = 200000, max_tokens = 32000 },
  m { id = "anthropic/claude-sonnet-4.6", name = "Claude Sonnet 4.6", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 }, context_window = 1000000, max_tokens = 64000 },
  m { id = "anthropic/claude-opus-4.6",   name = "Claude Opus 4.6",   api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 15, output = 75, cache_read = 1.5, cache_write = 18.75 }, context_window = 1000000, max_tokens = 64000 },
  -- Google
  m { id = "google/gemini-2.5-flash",       name = "Gemini 2.5 Flash",       api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 0.3, output = 2.5, cache_read = 0.075, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "google/gemini-2.5-pro",         name = "Gemini 2.5 Pro",         api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 2.5, output = 15, cache_read = 0.625, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "google/gemini-3-flash-preview", name = "Gemini 3 Flash Preview", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 0.6, output = 3.5, cache_read = 0, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  -- OpenAI
  m { id = "openai/gpt-4o",       name = "GPT-4o",       api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 2.5, output = 10, cache_read = 1.25, cache_write = 0 }, context_window = 128000, max_tokens = 16384 },
  m { id = "openai/gpt-4.1",      name = "GPT-4.1",      api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 2, output = 8, cache_read = 0.5, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "openai/gpt-4.1-mini", name = "GPT-4.1 Mini", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 0.4, output = 1.6, cache_read = 0.1, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "openai/gpt-4.1-nano", name = "GPT-4.1 Nano", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 0.1, output = 0.4, cache_read = 0.03, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "openai/o3",           name = "o3",            api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 2, output = 8, cache_read = 0.5, cache_write = 0 }, context_window = 200000, max_tokens = 100000 },
  m { id = "openai/o4-mini",      name = "o4-mini",       api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text", "image" }, cost = { input = 1.1, output = 4.4, cache_read = 0.275, cache_write = 0 }, context_window = 200000, max_tokens = 100000 },
  -- DeepSeek
  m { id = "deepseek/deepseek-chat-v3.1", name = "DeepSeek V3.1", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text" }, cost = { input = 0.3, output = 0.88, cache_read = 0.075, cache_write = 0 }, context_window = 65536, max_tokens = 8192 },
  m { id = "deepseek/deepseek-r1",        name = "DeepSeek R1",   api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text" }, cost = { input = 0.55, output = 2.19, cache_read = 0.14, cache_write = 0 }, context_window = 65536, max_tokens = 8192 },
  -- Mistral
  m { id = "mistralai/mistral-large",  name = "Mistral Large",  api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text" }, cost = { input = 2, output = 6, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "mistralai/devstral-medium",name = "Devstral Medium", api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text" }, cost = { input = 0.9, output = 2.7, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  -- Meta
  m { id = "meta-llama/llama-4-maverick",name = "Llama 4 Maverick",api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 0.27, output = 0.35, cache_read = 0, cache_write = 0 }, context_window = 1048576, max_tokens = 65536 },
  m { id = "meta-llama/llama-4-scout",  name = "Llama 4 Scout",  api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = false, input = { "text", "image" }, cost = { input = 0.15, output = 0.35, cache_read = 0, cache_write = 0 }, context_window = 512000, max_tokens = 65536 },
  -- xAI
  m { id = "x-ai/grok-4",        name = "Grok 4",        api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text" }, cost = { input = 6, output = 18, cache_read = 0, cache_write = 0 }, context_window = 256000, max_tokens = 16384 },
  -- Qwen
  m { id = "qwen/qwen3-coder",   name = "Qwen3 Coder",   api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text" }, cost = { input = 0.16, output = 0.64, cache_read = 0, cache_write = 0 }, context_window = 262144, max_tokens = 65536 },
  m { id = "qwen/qwen3-235b-a22b",name = "Qwen3 235B",   api = "openai-completions", provider = "openrouter", base_url = OR_URL, reasoning = true,  input = { "text" }, cost = { input = 0.14, output = 0.56, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 40960 },
}

---------------------------------------------------------------------------
-- xAI (direct)
---------------------------------------------------------------------------

M["xai"] = {
  m { id = "grok-3",      name = "Grok 3",       api = "openai-completions", provider = "xai", base_url = "https://api.x.ai/v1", reasoning = true,  input = { "text", "image" }, cost = { input = 3, output = 15, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 131072 },
  m { id = "grok-3-fast",  name = "Grok 3 Fast",  api = "openai-completions", provider = "xai", base_url = "https://api.x.ai/v1", reasoning = true,  input = { "text", "image" }, cost = { input = 5, output = 25, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 131072 },
  m { id = "grok-3-mini",  name = "Grok 3 Mini",  api = "openai-completions", provider = "xai", base_url = "https://api.x.ai/v1", reasoning = true,  input = { "text", "image" }, cost = { input = 0.3, output = 0.5, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 131072 },
}

---------------------------------------------------------------------------
-- Groq
---------------------------------------------------------------------------

M["groq"] = {
  m { id = "llama-3.3-70b-versatile", name = "Llama 3.3 70B",   api = "openai-completions", provider = "groq", base_url = "https://api.groq.com/openai/v1", reasoning = false, input = { "text" }, cost = { input = 0.59, output = 0.79, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "llama-3.1-8b-instant",    name = "Llama 3.1 8B",    api = "openai-completions", provider = "groq", base_url = "https://api.groq.com/openai/v1", reasoning = false, input = { "text" }, cost = { input = 0.05, output = 0.08, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 8000 },
  m { id = "qwen-qwq-32b",           name = "Qwen QwQ 32B",    api = "openai-completions", provider = "groq", base_url = "https://api.groq.com/openai/v1", reasoning = true,  input = { "text" }, cost = { input = 0.29, output = 0.39, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 32768 },
}

---------------------------------------------------------------------------
-- Cerebras
---------------------------------------------------------------------------

M["cerebras"] = {
  m { id = "llama-3.3-70b",   name = "Llama 3.3 70B",   api = "openai-completions", provider = "cerebras", base_url = "https://api.cerebras.ai/v1", reasoning = false, input = { "text" }, cost = { input = 0.85, output = 1.2, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 8192 },
  m { id = "llama-4-scout-17b",name = "Llama 4 Scout 17B",api = "openai-completions", provider = "cerebras", base_url = "https://api.cerebras.ai/v1", reasoning = false, input = { "text" }, cost = { input = 0.2, output = 0.6, cache_read = 0, cache_write = 0 }, context_window = 131072, max_tokens = 16384 },
}

---------------------------------------------------------------------------
-- Mistral (direct)
---------------------------------------------------------------------------

M["mistral"] = {
  m { id = "mistral-large-latest",   name = "Mistral Large",   api = "openai-completions", provider = "mistral", base_url = "https://api.mistral.ai/v1", reasoning = false, input = { "text" }, cost = { input = 2, output = 6, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "devstral-medium-latest", name = "Devstral Medium",  api = "openai-completions", provider = "mistral", base_url = "https://api.mistral.ai/v1", reasoning = false, input = { "text" }, cost = { input = 0.9, output = 2.7, cache_read = 0, cache_write = 0 }, context_window = 128000, max_tokens = 32768 },
  m { id = "mistral-small-latest",   name = "Mistral Small",    api = "openai-completions", provider = "mistral", base_url = "https://api.mistral.ai/v1", reasoning = false, input = { "text" }, cost = { input = 0.2, output = 0.6, cache_read = 0, cache_write = 0 }, context_window = 32000, max_tokens = 8192 },
}

---------------------------------------------------------------------------
-- Lookup helpers
---------------------------------------------------------------------------

--- Build an index { [provider] = { [model_id] = model } } for fast lookup.
---@return table
local function build_index()
  local idx = {}
  for provider, models in pairs(M) do
    if type(models) == "table" and models[1] then
      idx[provider] = {}
      for _, model in ipairs(models) do
        idx[provider][model.id] = model
      end
    end
  end
  return idx
end

local _index = nil
local function get_index()
  if not _index then _index = build_index() end
  return _index
end

--- Retrieve a specific model.
---@param provider string
---@param model_id string
---@return table|nil
function M.get_model(provider, model_id)
  local idx = get_index()
  return idx[provider] and idx[provider][model_id]
end

--- List all models for a provider (returns the rich model tables).
---@param provider string
---@return table[]
function M.get_models(provider)
  return M[provider] or {}
end

--- List all registered provider names.
---@return string[]
function M.get_providers()
  local out = {}
  for k, v in pairs(M) do
    if type(v) == "table" and v[1] then
      table.insert(out, k)
    end
  end
  table.sort(out)
  return out
end

--- Invalidate the lookup index (call after adding custom models).
function M.invalidate_index()
  _index = nil
end

return M
