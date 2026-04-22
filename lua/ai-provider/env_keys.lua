--- Environment-variable API-key resolution.
--- Mirrors pi-mono packages/ai/src/env-api-keys.ts.
local M = {}

---@type table<string, string>
local ENV_MAP = {
  openai                  = "OPENAI_API_KEY",
  ["azure-openai-responses"] = "AZURE_OPENAI_API_KEY",
  anthropic               = "ANTHROPIC_API_KEY",
  google                  = "GEMINI_API_KEY",
  groq                    = "GROQ_API_KEY",
  cerebras                = "CEREBRAS_API_KEY",
  xai                     = "XAI_API_KEY",
  openrouter              = "OPENROUTER_API_KEY",
  ["vercel-ai-gateway"]   = "AI_GATEWAY_API_KEY",
  zai                     = "ZAI_API_KEY",
  mistral                 = "MISTRAL_API_KEY",
  minimax                 = "MINIMAX_API_KEY",
  ["minimax-cn"]          = "MINIMAX_CN_API_KEY",
  huggingface             = "HF_TOKEN",
  fireworks               = "FIREWORKS_API_KEY",
  opencode                = "OPENCODE_API_KEY",
  ["opencode-go"]         = "OPENCODE_API_KEY",
  ["kimi-coding"]         = "KIMI_API_KEY",
  deepseek                = "DEEPSEEK_API_KEY",
}

--- Get the API key for a provider from environment variables.
---@param provider string
---@return string|nil
function M.get(provider)
  -- GitHub Copilot: env-var fallback only (credential_store is preferred)
  if provider == "github-copilot" then
    return os.getenv("COPILOT_GITHUB_TOKEN")
        or os.getenv("GH_TOKEN")
        or os.getenv("GITHUB_TOKEN")
  end

  -- Anthropic: OAuth token takes precedence
  if provider == "anthropic" then
    return os.getenv("ANTHROPIC_OAUTH_TOKEN") or os.getenv("ANTHROPIC_API_KEY")
  end

  local env_var = ENV_MAP[provider]
  if env_var then
    return os.getenv(env_var)
  end
  return nil
end

return M
