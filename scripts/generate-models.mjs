import { MODELS } from "/home/cjvnjde/projects/personal/pi-mono/packages/ai/dist/models.generated.js";

// Providers to emit (every provider pi-mono knows about).
const PROVIDERS = [
  "amazon-bedrock",
  "anthropic",
  "azure-openai-responses",
  "cerebras",
  "fireworks",
  "github-copilot",
  "google",
  "google-antigravity",
  "google-gemini-cli",
  "google-vertex",
  "groq",
  "huggingface",
  "kimi-coding",
  "minimax",
  "minimax-cn",
  "mistral",
  "opencode",
  "opencode-go",
  "openai",
  "openai-codex",
  "openrouter",
  "vercel-ai-gateway",
  "xai",
  "zai",
];
// APIs the Lua plugin implements (including stubs that gracefully error).
const SUPPORTED_APIS = new Set([
  "openai-completions",
  "openai-responses",
  "openai-codex-responses",
  "azure-openai-responses",
  "anthropic-messages",
  "google-generative-ai",
  "google-gemini-cli",
  "google-vertex",
  "mistral-conversations",
  "bedrock-converse-stream",
]);

// No more forced API rewrites: every API pi-mono emits now has a Lua
// handler (native, delegating, or stubbed with a clear error).
const FORCE_OPENAI_COMPLETIONS = new Set();
const GITHUB_COPILOT_FORCE_COMPLETIONS = false;

// snake_case map for compat keys
const COMPAT_KEY_MAP = {
  supportsStore: "supports_store",
  supportsDeveloperRole: "supports_developer_role",
  supportsReasoningEffort: "supports_reasoning_effort",
  supportsUsageInStreaming: "supports_usage_in_streaming",
  maxTokensField: "max_tokens_field",
  requiresToolResultName: "requires_tool_result_name",
  requiresAssistantAfterToolResult: "requires_assistant_after_tool_result",
  requiresThinkingAsText: "requires_thinking_as_text",
  thinkingFormat: "thinking_format",
  reasoningEffortMap: "reasoning_effort_map",
  supportsStrictMode: "supports_strict_mode",
  cacheControlFormat: "cache_control_format",
  sendSessionAffinityHeaders: "send_session_affinity_headers",
  zaiToolStream: "zai_tool_stream",
  openRouterRouting: "open_router_routing",
  vercelGatewayRouting: "vercel_gateway_routing",
};

const esc = (s) => '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';

function luaVal(v) {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : "nil";
  if (typeof v === "string") return esc(v);
  if (Array.isArray(v)) return "{ " + v.map(luaVal).join(", ") + " }";
  if (typeof v === "object") {
    const parts = [];
    for (const [k, val] of Object.entries(v)) {
      const mk = COMPAT_KEY_MAP[k] || k;
      // use identifier syntax when safe
      const keyIsId = /^[A-Za-z_][A-Za-z0-9_]*$/.test(mk);
      parts.push((keyIsId ? mk : "[" + esc(mk) + "]") + " = " + luaVal(val));
    }
    return "{ " + parts.join(", ") + " }";
  }
  return "nil";
}

function emitModel(m) {
  // Transform cost keys
  const cost = {
    input: m.cost.input,
    output: m.cost.output,
    cache_read: m.cost.cacheRead,
    cache_write: m.cost.cacheWrite,
  };
  const entry = {
    id: m.id,
    name: m.name,
    api: m.api,
    provider: m.provider,
    base_url: m.baseUrl,
    reasoning: m.reasoning,
    input: m.input,
    cost,
    context_window: m.contextWindow,
    max_tokens: m.maxTokens,
  };
  if (m.headers) entry.headers = m.headers;
  if (m.compat) entry.compat = m.compat;

  // Use `m { ... }` helper
  const parts = [];
  for (const [k, v] of Object.entries(entry)) {
    const keyIsId = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k);
    parts.push((keyIsId ? k : "[" + esc(k) + "]") + " = " + luaVal(v));
  }
  return "  m { " + parts.join(", ") + " },";
}

let out = `--- Model definitions for all supported providers.
---
--- Auto-generated from pi-mono packages/ai/src/models.generated.ts.
--- Run scripts/generate-models.mjs to regenerate.
---
--- Only models whose \`api\` is supported by this plugin are included:
---   - anthropic-messages
---   - openai-completions
---   - google-generative-ai
--- Models using other APIs (openai-responses, bedrock-converse-stream,
--- mistral-conversations, google-gemini-cli, google-vertex, ...) are
--- omitted and must be added via \`custom_models\` or a custom API provider.
local M = {}

--- Helper: merge defaults into each model entry.
local function m(t)
  t.input = t.input or { "text" }
  t.cost = t.cost or { input = 0, output = 0, cache_read = 0, cache_write = 0 }
  return t
end

`;

for (const p of PROVIDERS) {
  const models = MODELS[p];
  if (!models) continue;
  const filtered = Object.values(models)
    .map((m) => {
      if (FORCE_OPENAI_COMPLETIONS.has(p)) return { ...m, api: "openai-completions" };
      if (p === "github-copilot" && GITHUB_COPILOT_FORCE_COMPLETIONS && m.api === "openai-responses") {
        // Copilot exposes these via chat/completions too; force completions.
        return { ...m, api: "openai-completions" };
      }
      return m;
    })
    .filter((m) => SUPPORTED_APIS.has(m.api));
  if (filtered.length === 0) {
    out += `---------------------------------------------------------------------------\n-- ${p} (no models with supported APIs)\n---------------------------------------------------------------------------\nM[${esc(p)}] = {}\n\n`;
    continue;
  }
  out += `---------------------------------------------------------------------------\n-- ${p}\n---------------------------------------------------------------------------\nM[${esc(p)}] = {\n`;
  for (const mm of filtered) out += emitModel(mm) + "\n";
  out += "}\n\n";
}

out += `---------------------------------------------------------------------------
-- Lookup helpers
---------------------------------------------------------------------------

--- Build an index { [provider] = { [model_id] = model } } for fast lookup.
---@return table
local function build_index()
  local idx = {}
  for provider, models in pairs(M) do
    if type(models) == "table" and (models[1] or next(models) == nil) then
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
    if type(v) == "table" and (v[1] or next(v) == nil) then
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
`;

process.stdout.write(out);
