--- Shared curl streaming utility for SSE-based API providers.
local M = {}

local sse = require "ai-provider.sse"

--- Start a streaming curl POST and parse SSE events.
---
---@param opts table
---  - url: string
---  - headers: table<string,string>
---  - body: table   (JSON-encoded automatically)
---  - on_event: fun(event_type: string|nil, data: string)
---  - on_error: fun(err: string)
---  - on_done: fun()
---@return number job_id   (pass to EventStream:set_job_id)
function M.stream(opts)
  local parser = sse.new()
  local stderr_chunks = {}

  parser:on_event(function(event_type, data)
    if opts.on_event then opts.on_event(event_type, data) end
  end)

  -- Write body to temp file to avoid shell-escaping issues with large JSON.
  local body_json = vim.json.encode(opts.body)
  local tmp = vim.fn.tempname()
  local f = io.open(tmp, "w")
  if f then
    f:write(body_json)
    f:close()
  end

  -- Build curl command
  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "-X", "POST",
  }
  for key, value in pairs(opts.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, key .. ": " .. value)
  end
  table.insert(args, "-d")
  table.insert(args, "@" .. tmp)
  table.insert(args, opts.url)

  -- Track partial lines across on_stdout callbacks.
  -- vim.fn.jobstart splits output by \n: each element is a line fragment,
  -- and empty strings ("") represent newline characters (i.e. blank lines).
  -- The first element of each callback continues the last element of the
  -- previous one, and the last element may be an incomplete partial line.
  local stdout_pending = ""
  local stderr_pending = ""

  local job_id = vim.fn.jobstart(args, {
    on_stdout = function(_, data, _)
      -- Reassemble partial lines across callbacks
      data[1] = stdout_pending .. data[1]
      stdout_pending = data[#data]

      -- Feed complete lines (all except the last, which may be partial).
      -- Empty strings become "\n" — the blank line the SSE parser needs
      -- to flush each event frame.
      for i = 1, #data - 1 do
        parser:feed(data[i] .. "\n")
      end
    end,
    on_stderr = function(_, data, _)
      data[1] = stderr_pending .. data[1]
      stderr_pending = data[#data]

      for i = 1, #data - 1 do
        if data[i] ~= "" then
          table.insert(stderr_chunks, data[i])
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      os.remove(tmp)

      -- Feed any remaining partial line before finishing
      if stdout_pending ~= "" then
        parser:feed(stdout_pending .. "\n")
      end
      parser:finish()

      if exit_code ~= 0 then
        local err = table.concat(stderr_chunks, "\n")
        if err == "" then err = "curl exited with code " .. exit_code end
        if opts.on_error then
          vim.schedule(function() opts.on_error(err) end)
        end
      elseif not parser:had_events() then
        -- No SSE events were emitted – the API likely returned a raw
        -- (non-SSE) error response.  Surface it instead of silently
        -- reporting an empty result.
        local raw = parser:get_unknown_data()
        if raw == "" then raw = table.concat(stderr_chunks, "\n") end
        if raw == "" then raw = "No response received from server" end
        if opts.on_error then
          vim.schedule(function() opts.on_error(raw) end)
        end
      else
        if opts.on_done then
          vim.schedule(function() opts.on_done() end)
        end
      end
    end,
  })

  return job_id
end

return M
