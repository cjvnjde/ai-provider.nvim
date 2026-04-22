--- Context-overflow error detection.
--- Mirrors pi-mono packages/ai/src/utils/overflow.ts.
local M = {}

local OVERFLOW_PATTERNS = {
  "prompt is too long",
  "request_too_large",
  "input is too long for requested model",
  "exceeds the context window",
  "input token count.*exceeds the maximum",
  "maximum prompt length is %d+",
  "reduce the length of the messages",
  "maximum context length is %d+ tokens",
  "exceeds the limit of %d+",
  "exceeds the available context size",
  "greater than the context length",
  "context window exceeds limit",
  "exceeded model token limit",
  "too large for model with %d+ maximum context length",
  "model_context_window_exceeded",
  "prompt too long; exceeded .*context length",
  "context[_ ]length[_ ]exceeded",
  "too many tokens",
  "token limit exceeded",
  "^4%d%d%s*%(no body%)",
}

local NON_OVERFLOW_PATTERNS = {
  "^throttling error:",
  "^service unavailable:",
  "rate limit",
  "too many requests",
}

local function match_any(s, patterns)
  local lower = s:lower()
  for _, p in ipairs(patterns) do
    if lower:find(p) then return true end
  end
  return false
end

--- Check if an assistant message represents a context-overflow error.
---@param message table  AssistantMessage
---@param context_window? number  optional context-window to detect silent overflow
---@return boolean
function M.is_context_overflow(message, context_window)
  if message.stop_reason == "error" and message.error_message then
    if not match_any(message.error_message, NON_OVERFLOW_PATTERNS)
        and match_any(message.error_message, OVERFLOW_PATTERNS) then
      return true
    end
  end
  if context_window and message.stop_reason == "stop" and message.usage then
    local input_tokens = (message.usage.input or 0) + (message.usage.cache_read or 0)
    if input_tokens > context_window then return true end
  end
  return false
end

return M
