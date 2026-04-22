# scripts

## generate-models.mjs

Regenerates `lua/ai-provider/models.lua` from pi-mono's built model catalog
(`packages/ai/dist/models.generated.js`).

### Usage

```sh
# Build pi-mono first (in the pi-mono repo):
#   npm -w @mariozechner/pi-ai run build

# Then from the plugin root:
node scripts/generate-models.mjs > lua/ai-provider/models.lua
```

### What it does

- Enumerates every provider pi-mono knows about (24 providers as of this
  writing — Anthropic, Google, OpenAI, OpenAI Codex, Azure OpenAI, Amazon
  Bedrock, Google Vertex, Google Gemini CLI, GitHub Copilot, OpenRouter,
  Vercel AI Gateway, xAI, Groq, Cerebras, z.ai, Mistral, Minimax, Minimax
  CN, Hugging Face, Fireworks, Opencode, Opencode-Go, Kimi Coding, Google
  Antigravity).
- Emits every model whose `api` is one of the APIs implemented in
  `lua/ai-provider/providers/`:
  `openai-completions`, `openai-responses`, `openai-codex-responses`,
  `azure-openai-responses`, `anthropic-messages`, `google-generative-ai`,
  `google-gemini-cli`, `google-vertex`, `mistral-conversations`, and
  `bedrock-converse-stream`.
- Converts TS field casing to Lua snake_case (`baseUrl` → `base_url`,
  `cacheRead` → `cache_read`, `contextWindow` → `context_window`,
  `maxTokens` → `max_tokens`, `supportsStore` → `supports_store`, etc.).
- Preserves `compat` and `headers` settings verbatim.

The resulting `models.lua` is ~1000 lines of data + a handful of lookup
helpers (`get_model`, `get_models`, `get_providers`).

### When to run

Any time pi-mono's `models.generated.ts` changes (new/updated models,
pricing changes, new reasoning capabilities, new provider endpoints).
