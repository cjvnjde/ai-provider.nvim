--- Server-Sent Events (SSE) parser.
---
--- Handles both OpenAI-style (`data:` only) and Anthropic-style
--- (`event:` + `data:`) SSE frames.
local M = {}

--- Create a new SSE parser.
---@return table Parser instance with :feed(chunk), :on_event(cb), :finish()
function M.new()
  local parser = {
    _buffer = "",
    _current_event = nil,
    _current_data = {},
    _callback = nil,
  }

  --- Set the callback for parsed events.
  ---@param callback fun(event_type: string|nil, data: string)
  function parser:on_event(callback)
    self._callback = callback
  end

  --- Flush the accumulated event.
  function parser:_flush()
    if #self._current_data == 0 then return end
    local data = table.concat(self._current_data, "\n")
    if self._callback then
      self._callback(self._current_event, data)
    end
    self._current_event = nil
    self._current_data = {}
  end

  --- Feed raw string chunks from curl stdout.
  ---@param chunk string
  function parser:feed(chunk)
    self._buffer = self._buffer .. chunk

    while true do
      local nl = self._buffer:find("\n")
      if not nl then break end

      local line = self._buffer:sub(1, nl - 1)
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      self._buffer = self._buffer:sub(nl + 1)

      if line == "" then
        -- Empty line → end of SSE frame
        self:_flush()
      elseif line:sub(1, 6) == "event:" then
        self._current_event = vim.trim(line:sub(7))
      elseif line:sub(1, 5) == "data:" then
        table.insert(self._current_data, vim.trim(line:sub(6)))
      end
      -- Ignore comments (lines starting with ':') and unknown fields.
    end
  end

  --- Flush any remaining buffered data.
  function parser:finish()
    if #self._current_data > 0 then
      self:_flush()
    end
  end

  return parser
end

return M
