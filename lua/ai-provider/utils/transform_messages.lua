--- Cross-provider message-transformation shared utility.
---
--- Mirrors pi-mono packages/ai/src/providers/transform-messages.ts.
---
--- Responsibilities (bottom-up):
---
--- 1. Downgrade images to text placeholders for non-vision models.
--- 2. Drop empty thinking blocks, convert thinking → text for cross-model
---    replay, drop redacted thinking for foreign models.
--- 3. Normalise tool-call IDs via a caller-supplied normaliser (used by
---    Anthropic / Mistral / OpenAI-Completions to meet their ID constraints).
--- 4. Insert synthetic "No result provided" tool-results for any tool
---    calls that don't have a matching toolResult in the history.
--- 5. Skip errored/aborted assistant turns entirely (they are replay poison).
---
--- The caller passes a `normalize_tool_call_id(id, model, assistant_msg)`
--- function which is only invoked for *foreign* assistant messages (i.e.
--- produced by a different provider/api/model). If the function returns a
--- new id it's recorded and applied transitively to later tool_result
--- messages in the same conversation.
local M = {}

local USER_IMG_PLACEHOLDER = "(image omitted: model does not support images)"
local TOOL_IMG_PLACEHOLDER = "(tool image omitted: model does not support images)"

local function replace_images_with_placeholder(content, placeholder)
  local result = {}
  local prev_placeholder = false
  for _, block in ipairs(content) do
    if block.type == "image" then
      if not prev_placeholder then
        table.insert(result, { type = "text", text = placeholder })
      end
      prev_placeholder = true
    else
      table.insert(result, block)
      prev_placeholder = block.type == "text" and block.text == placeholder
    end
  end
  return result
end

local function supports_image(model)
  if not model or not model.input then return false end
  for _, kind in ipairs(model.input) do
    if kind == "image" then return true end
  end
  return false
end

local function downgrade_unsupported_images(messages, model)
  if supports_image(model) then return messages end
  local out = {}
  for _, msg in ipairs(messages) do
    if msg.role == "user" and type(msg.content) == "table" then
      local clone = vim.deepcopy(msg)
      clone.content = replace_images_with_placeholder(msg.content, USER_IMG_PLACEHOLDER)
      table.insert(out, clone)
    elseif msg.role == "toolResult" and type(msg.content) == "table" then
      local clone = vim.deepcopy(msg)
      clone.content = replace_images_with_placeholder(msg.content, TOOL_IMG_PLACEHOLDER)
      table.insert(out, clone)
    else
      table.insert(out, msg)
    end
  end
  return out
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Transform a conversation for a target model.
---
---@param messages table[]           Input messages.
---@param model table                Target model.
---@param normalize_tool_call_id? fun(id:string, model:table, source:table):string
---@return table[] transformed
function M.transform(messages, model, normalize_tool_call_id)
  local image_aware = downgrade_unsupported_images(messages, model)
  local tool_call_id_map = {}  -- original → normalised
  local transformed = {}

  for _, msg in ipairs(image_aware) do
    if msg.role == "user" then
      table.insert(transformed, msg)

    elseif msg.role == "toolResult" then
      local mapped = tool_call_id_map[msg.tool_call_id]
      if mapped and mapped ~= msg.tool_call_id then
        local clone = vim.deepcopy(msg)
        clone.tool_call_id = mapped
        table.insert(transformed, clone)
      else
        table.insert(transformed, msg)
      end

    elseif msg.role == "assistant" then
      local is_same_model =
        msg.provider == model.provider
        and msg.api == model.api
        and msg.model == model.id

      local new_content = {}
      for _, block in ipairs(msg.content or {}) do
        if block.type == "thinking" then
          if block.redacted then
            if is_same_model then table.insert(new_content, block) end
          elseif is_same_model and block.thinking_signature and #block.thinking_signature > 0 then
            table.insert(new_content, block)
          elseif block.thinking and trim(block.thinking) ~= "" then
            if is_same_model then
              table.insert(new_content, block)
            else
              table.insert(new_content, { type = "text", text = block.thinking })
            end
          end
        elseif block.type == "text" then
          if is_same_model then
            table.insert(new_content, block)
          else
            table.insert(new_content, { type = "text", text = block.text })
          end
        elseif block.type == "toolCall" then
          local tc = block
          if not is_same_model and tc.thought_signature then
            tc = vim.deepcopy(block)
            tc.thought_signature = nil
          end
          if not is_same_model and normalize_tool_call_id then
            local new_id = normalize_tool_call_id(tc.id, model, msg)
            if new_id and new_id ~= tc.id then
              tool_call_id_map[tc.id] = new_id
              if tc == block then tc = vim.deepcopy(block) end
              tc.id = new_id
            end
          end
          table.insert(new_content, tc)
        else
          table.insert(new_content, block)
        end
      end

      local clone = vim.deepcopy(msg)
      clone.content = new_content
      table.insert(transformed, clone)
    else
      table.insert(transformed, msg)
    end
  end

  -- Second pass: drop errored/aborted assistants and insert synthetic
  -- toolResult messages for any orphaned tool calls so the next turn is
  -- API-valid (required by OpenAI / Anthropic / Mistral, etc.).
  local result = {}
  local pending_tool_calls = {}
  local seen_tool_result_ids = {}

  local function flush_orphans()
    if #pending_tool_calls == 0 then return end
    for _, tc in ipairs(pending_tool_calls) do
      if not seen_tool_result_ids[tc.id] then
        table.insert(result, {
          role = "toolResult",
          tool_call_id = tc.id,
          tool_name = tc.name,
          content = { { type = "text", text = "No result provided" } },
          is_error = true,
          timestamp = os.time() * 1000,
        })
      end
    end
    pending_tool_calls = {}
    seen_tool_result_ids = {}
  end

  for _, msg in ipairs(transformed) do
    if msg.role == "assistant" then
      flush_orphans()

      if msg.stop_reason == "error" or msg.stop_reason == "aborted" then
        -- Skip broken assistant turns entirely.
      else
        local tool_calls = {}
        for _, b in ipairs(msg.content or {}) do
          if b.type == "toolCall" then table.insert(tool_calls, b) end
        end
        if #tool_calls > 0 then
          pending_tool_calls = tool_calls
          seen_tool_result_ids = {}
        end
        table.insert(result, msg)
      end
    elseif msg.role == "toolResult" then
      seen_tool_result_ids[msg.tool_call_id] = true
      table.insert(result, msg)
    elseif msg.role == "user" then
      flush_orphans()
      table.insert(result, msg)
    else
      table.insert(result, msg)
    end
  end
  flush_orphans()

  return result
end

return M
