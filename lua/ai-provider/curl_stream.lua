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

  local job_id = vim.fn.jobstart(args, {
    on_stdout = function(_, data, _)
      for _, chunk in ipairs(data) do
        if chunk ~= "" then
          parser:feed(chunk .. "\n")
        end
      end
    end,
    on_stderr = function(_, data, _)
      for _, chunk in ipairs(data) do
        if chunk ~= "" then
          table.insert(stderr_chunks, chunk)
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      os.remove(tmp)
      parser:finish()

      if exit_code ~= 0 then
        local err = table.concat(stderr_chunks, "\n")
        if err == "" then err = "curl exited with code " .. exit_code end
        if opts.on_error then
          vim.schedule(function() opts.on_error(err) end)
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
