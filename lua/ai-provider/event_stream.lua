--- EventStream – async event push / subscribe stream for AI responses.
---
--- Mirrors pi-mono's AssistantMessageEventStream (packages/ai/src/utils/event-stream.ts).
---
--- Usage (producer):
---   local es = EventStream.new()
---   es:push({ type = "text_delta", delta = "Hi", ... })
---   es:push({ type = "done", reason = "stop", message = msg })
---
--- Usage (consumer):
---   es:on(function(event) ... end)
---   es:on_done(function(message) ... end)
---   es:on_error(function(message) ... end)
---   es:result(function(message) ... end)
---   es:stop()  -- cancel

local EventStream = {}
EventStream.__index = EventStream

function EventStream.new()
  return setmetatable({
    _listeners = {},
    _done_listeners = {},
    _error_listeners = {},
    _finished = false,
    _result = nil,
    _result_listeners = {},
    _job_id = nil,
  }, EventStream)
end

--- Register a listener for ALL events.
---@param callback fun(event: table)
---@return EventStream self
function EventStream:on(callback)
  table.insert(self._listeners, callback)
  return self
end

--- Register a listener for successful completion.
---@param callback fun(message: table)
---@return EventStream self
function EventStream:on_done(callback)
  table.insert(self._done_listeners, callback)
  if self._finished and self._result and self._result.stop_reason ~= "error" and self._result.stop_reason ~= "aborted" then
    vim.schedule(function() callback(self._result) end)
  end
  return self
end

--- Register a listener for error / abort.
---@param callback fun(message: table)
---@return EventStream self
function EventStream:on_error(callback)
  table.insert(self._error_listeners, callback)
  if self._finished and self._result and (self._result.stop_reason == "error" or self._result.stop_reason == "aborted") then
    vim.schedule(function() callback(self._result) end)
  end
  return self
end

--- Get the final AssistantMessage (success or error) via callback.
---@param callback fun(message: table)
---@return EventStream self
function EventStream:result(callback)
  if self._finished and self._result then
    vim.schedule(function() callback(self._result) end)
  else
    table.insert(self._result_listeners, callback)
  end
  return self
end

--- Push an event to all listeners.
---@param event table
function EventStream:push(event)
  if self._finished then return end

  for _, listener in ipairs(self._listeners) do
    listener(event)
  end

  if event.type == "done" then
    self._finished = true
    self._result = event.message
    for _, cb in ipairs(self._done_listeners) do cb(event.message) end
    for _, cb in ipairs(self._result_listeners) do cb(event.message) end
  elseif event.type == "error" then
    self._finished = true
    self._result = event.error
    for _, cb in ipairs(self._error_listeners) do cb(event.error) end
    for _, cb in ipairs(self._result_listeners) do cb(event.error) end
  end
end

--- Mark the stream as finished (idempotent, no events emitted).
function EventStream:finish()
  self._finished = true
end

--- Cancel the stream (stops the underlying curl job).
function EventStream:stop()
  if not self._finished then
    self._finished = true
    if self._job_id and self._job_id > 0 then
      pcall(vim.fn.jobstop, self._job_id)
    end
  end
end

--- Attach the job ID so stop() can cancel it.
---@param job_id number
function EventStream:set_job_id(job_id)
  self._job_id = job_id
end

---@return boolean
function EventStream:is_done()
  return self._finished
end

return EventStream
