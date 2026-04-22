--- Type constants and constructors for ai-provider.
--- Mirrors pi-mono's packages/ai/src/types.ts
local M = {}

--- API types (wire protocol)
M.API = {
  OPENAI_COMPLETIONS     = "openai-completions",
  OPENAI_RESPONSES       = "openai-responses",
  OPENAI_CODEX_RESPONSES = "openai-codex-responses",
  AZURE_OPENAI_RESPONSES = "azure-openai-responses",
  ANTHROPIC_MESSAGES     = "anthropic-messages",
  BEDROCK_CONVERSE_STREAM = "bedrock-converse-stream",
  MISTRAL_CONVERSATIONS  = "mistral-conversations",
  GOOGLE_GENERATIVE_AI   = "google-generative-ai",
  GOOGLE_GEMINI_CLI      = "google-gemini-cli",
  GOOGLE_VERTEX          = "google-vertex",
}

--- Provider names
M.PROVIDER = {
  AMAZON_BEDROCK   = "amazon-bedrock",
  ANTHROPIC        = "anthropic",
  GOOGLE           = "google",
  GOOGLE_GEMINI_CLI = "google-gemini-cli",
  GOOGLE_ANTIGRAVITY = "google-antigravity",
  GOOGLE_VERTEX    = "google-vertex",
  OPENAI           = "openai",
  AZURE_OPENAI_RESPONSES = "azure-openai-responses",
  OPENAI_CODEX     = "openai-codex",
  GITHUB_COPILOT   = "github-copilot",
  OPENROUTER       = "openrouter",
  VERCEL_AI_GATEWAY = "vercel-ai-gateway",
  XAI              = "xai",
  GROQ             = "groq",
  CEREBRAS         = "cerebras",
  ZAI              = "zai",
  MISTRAL          = "mistral",
  MINIMAX          = "minimax",
  MINIMAX_CN       = "minimax-cn",
  HUGGINGFACE      = "huggingface",
  FIREWORKS        = "fireworks",
  OPENCODE         = "opencode",
  OPENCODE_GO      = "opencode-go",
  KIMI_CODING      = "kimi-coding",
}

--- Reasoning / thinking levels (unified across providers)
---@alias ThinkingLevel "minimal"|"low"|"medium"|"high"|"xhigh"

--- Stop reasons
---@alias StopReason "stop"|"length"|"toolUse"|"error"|"aborted"

--- Create an empty usage object.
---@return table
function M.empty_usage()
  return {
    input = 0,
    output = 0,
    reasoning_tokens = 0,
    cache_read = 0,
    cache_write = 0,
    total_tokens = 0,
    cost = { input = 0, output = 0, cache_read = 0, cache_write = 0, total = 0 },
  }
end

--- Create a new AssistantMessage skeleton.
---@param model table Model definition
---@return table
function M.new_assistant_message(model)
  return {
    role = "assistant",
    content = {},
    api = model.api,
    provider = model.provider,
    model = model.id,
    usage = M.empty_usage(),
    stop_reason = "stop",
    timestamp = os.time() * 1000,
  }
end

--- Calculate cost from model pricing and usage.
---@param model table Model with cost fields
---@param usage table Usage with token counts
function M.calculate_cost(model, usage)
  if not model.cost then return end
  usage.cost.input = (model.cost.input / 1000000) * usage.input
  usage.cost.output = (model.cost.output / 1000000) * usage.output
  usage.cost.cache_read = (model.cost.cache_read / 1000000) * usage.cache_read
  usage.cost.cache_write = (model.cost.cache_write / 1000000) * usage.cache_write
  usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write
end

--- Clamp reasoning level for providers that don't yet support "xhigh".
--- Most providers map "xhigh" → "high"; Anthropic adaptive-thinking providers
--- (Opus 4.6 / 4.7) handle "xhigh" natively in their own mapper.
---@param level string|nil
---@return string|nil
function M.clamp_reasoning(level)
  if level == "xhigh" then return "high" end
  return level
end

--- Check whether a model supports the "xhigh" thinking level.
--- Mirrors pi-mono's supportsXhigh().
---@param model table
---@return boolean
function M.supports_xhigh(model)
  local id = model and model.id or ""
  if id:find("gpt%-5%.2") or id:find("gpt%-5%.3") or id:find("gpt%-5%.4") then
    return true
  end
  if id:find("opus%-4%-6") or id:find("opus%-4%.6")
      or id:find("opus%-4%-7") or id:find("opus%-4%.7") then
    return true
  end
  return false
end

--- Compute thinking budget + maxTokens for budget-based providers (Anthropic, Google).
---@param base_max_tokens number
---@param model_max_tokens number
---@param level string ThinkingLevel
---@param custom_budgets? table
---@return number max_tokens
---@return number thinking_budget
function M.adjust_max_tokens_for_thinking(base_max_tokens, model_max_tokens, level, custom_budgets)
  local defaults = { minimal = 1024, low = 2048, medium = 8192, high = 16384 }
  local budgets = vim.tbl_extend("force", defaults, custom_budgets or {})
  local clamped = M.clamp_reasoning(level) or "high"
  local budget = budgets[clamped] or 8192
  local max_tokens = math.min(base_max_tokens + budget, model_max_tokens)
  if max_tokens <= budget then
    budget = math.max(0, max_tokens - 1024)
  end
  return max_tokens, budget
end

return M
