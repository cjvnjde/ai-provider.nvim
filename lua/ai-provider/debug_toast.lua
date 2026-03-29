--- Debug toast – live streaming preview in a bottom-right floating window.
---
--- Shows AI response tokens, thinking, and tool calls as they stream in.
--- Intended for development / debugging.  Enable via setup:
---
---   require("ai-provider").setup({
---     debug_toast = { enabled = true },
---   })
---
--- Options (all optional):
---   enabled        boolean   default false
---   max_width      number    default 60
---   max_height     number    default 15
---   dismiss_delay  number    ms before auto-dismiss after done/error (default 3000)
local M = {}

--- Hard cap on raw lines kept in memory.
local MAX_RAW_LINES = 200

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

---@class DebugToastState
---@field buf number
---@field win number
---@field dismiss_timer uv_timer_t|nil
---@field raw_lines string[]

---@type DebugToastState|nil
local toast = nil

---------------------------------------------------------------------------
-- Config helpers
---------------------------------------------------------------------------

---@return { enabled: boolean, max_width: number, max_height: number, dismiss_delay: number }
local function get_config()
  local dc = (require("ai-provider.config").get()).debug_toast or {}
  return {
    enabled       = dc.enabled == true,
    max_width     = dc.max_width or 60,
    max_height    = dc.max_height or 15,
    dismiss_delay = dc.dismiss_delay or 3000,
  }
end

--- Whether the debug toast is enabled.
---@return boolean
function M.is_enabled()
  return get_config().enabled
end

---------------------------------------------------------------------------
-- Dismiss timer
---------------------------------------------------------------------------

local function cancel_dismiss_timer()
  if toast and toast.dismiss_timer then
    pcall(function()
      toast.dismiss_timer:stop()
      toast.dismiss_timer:close()
    end)
    toast.dismiss_timer = nil
  end
end

local function schedule_dismiss()
  if not toast then return end
  cancel_dismiss_timer()
  local delay = get_config().dismiss_delay
  local timer = vim.uv.new_timer()
  toast.dismiss_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    pcall(function()
      timer:stop()
      timer:close()
    end)
    M.dismiss()
  end))
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local render_dirty = false

--- Schedule a render on the next event loop tick (coalesces rapid updates).
local function request_render()
  if render_dirty then return end
  render_dirty = true
  vim.schedule(function()
    render_dirty = false
    if not toast then return end
    if not vim.api.nvim_buf_is_valid(toast.buf) then
      M.dismiss()
      return
    end

    local cfg = get_config()
    local cw = cfg.max_width - 2 -- 1-char padding each side

    -- Wrap raw lines → display lines (skip empty lines)
    local wrapped = {}
    for _, raw in ipairs(toast.raw_lines) do
      if #raw > 0 then
        if #raw <= cw then
          table.insert(wrapped, " " .. raw)
        else
          local pos = 1
          while pos <= #raw do
            table.insert(wrapped, " " .. raw:sub(pos, pos + cw - 1))
            pos = pos + cw
          end
        end
      end
    end

    -- Keep last max_height lines
    local height = math.min(#wrapped, cfg.max_height)
    local display = {}
    if height > 0 then
      for i = #wrapped - height + 1, #wrapped do
        table.insert(display, wrapped[i])
      end
    end

    if #display == 0 then
      display = { " " }
      height = 1
    end

    pcall(vim.api.nvim_buf_set_lines, toast.buf, 0, -1, false, display)

    -- Reposition – grows upward from the bottom-right
    if toast.win and vim.api.nvim_win_is_valid(toast.win) then
      pcall(vim.api.nvim_win_set_config, toast.win, {
        relative = "editor",
        anchor   = "SE",
        row      = vim.o.lines - vim.o.cmdheight - 1,
        col      = vim.o.columns - 1,
        width    = cfg.max_width,
        height   = height,
      })
    end
  end)
end

---------------------------------------------------------------------------
-- Raw-line helpers
---------------------------------------------------------------------------

local function trim_raw()
  if not toast then return end
  while #toast.raw_lines > MAX_RAW_LINES do
    table.remove(toast.raw_lines, 1)
  end
end

local function append_text(text)
  if not toast then return end
  local parts = vim.split(text, "\n", { plain = true })

  -- First fragment extends the current (last) line
  local n = #toast.raw_lines
  if n > 0 then
    toast.raw_lines[n] = toast.raw_lines[n] .. parts[1]
  else
    table.insert(toast.raw_lines, parts[1])
  end

  -- Remaining fragments start new lines
  for i = 2, #parts do
    table.insert(toast.raw_lines, parts[i])
  end

  trim_raw()
  request_render()
end

local function append_section(header)
  if not toast then return end
  -- Replace trailing empty placeholder with the header
  local n = #toast.raw_lines
  if n > 0 and toast.raw_lines[n] == "" then
    toast.raw_lines[n] = header
  else
    table.insert(toast.raw_lines, header)
  end
  -- New empty line ready for subsequent text
  table.insert(toast.raw_lines, "")
  trim_raw()
  request_render()
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

local function open()
  if toast then
    cancel_dismiss_timer()
    toast.raw_lines = {}
    request_render()
    return
  end

  local cfg = get_config()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " " })

  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    anchor    = "SE",
    row       = vim.o.lines - vim.o.cmdheight - 1,
    col       = vim.o.columns - 1,
    width     = cfg.max_width,
    height    = 1,
    style     = "minimal",
    border    = "rounded",
    focusable = false,
    noautocmd = true,
    zindex    = 99,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:Comment,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  toast = {
    buf           = buf,
    win           = win,
    dismiss_timer = nil,
    raw_lines     = {},
  }
end

--- Dismiss the debug toast immediately.
function M.dismiss()
  local t = toast
  if not t then return end

  cancel_dismiss_timer()
  toast = nil

  if t.win and vim.api.nvim_win_is_valid(t.win) then
    pcall(vim.api.nvim_win_close, t.win, true)
  end
  if t.buf and vim.api.nvim_buf_is_valid(t.buf) then
    pcall(vim.api.nvim_buf_delete, t.buf, { force = true })
  end
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------

function M._handle(event)
  local t = event.type

  if t == "start" then
    open()
    local model    = event.partial and event.partial.model or "?"
    local provider = event.partial and event.partial.provider or ""
    append_section("⏳ " .. provider .. " / " .. model)

  elseif t == "thinking_start" then
    append_section("💭 Thinking")

  elseif t == "thinking_delta" then
    append_text(event.delta)

  elseif t == "text_start" then
    append_section("📝 Response")

  elseif t == "text_delta" then
    append_text(event.delta)

  elseif t == "toolcall_start" then
    local name = ""
    if event.partial and event.partial.content then
      local last = event.partial.content[#event.partial.content]
      if last then name = last.name or "" end
    end
    append_section("🔧 " .. name)

  elseif t == "toolcall_delta" then
    append_text(event.delta)

  elseif t == "done" then
    local msg = event.message
    if msg and msg.usage then
      local u = msg.usage
      local cost = ""
      if u.cost and u.cost.total and u.cost.total > 0 then
        cost = string.format(" · $%.4f", u.cost.total)
      end
      local summary = string.format(
        "✓ %d in · %d out · %d cached",
        u.input or 0, u.output or 0, u.cache_read or 0
      )
      if (u.reasoning_tokens or 0) > 0 then
        summary = summary .. string.format(" · %d reasoning", u.reasoning_tokens)
      end
      append_section(summary .. cost)
    else
      append_section("✓ Done")
    end
    schedule_dismiss()

  elseif t == "error" then
    local err = event.error and event.error.error_message or "unknown error"
    if #err > 120 then err = err:sub(1, 117) .. "…" end
    append_section("✗ " .. err)
    schedule_dismiss()
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Attach to an EventStream to show debug output.
--- No-op when debug_toast is disabled.
---@param es table EventStream
---@return table es  (passthrough for chaining)
function M.attach(es)
  if not M.is_enabled() then return es end
  es:on(function(event) M._handle(event) end)
  return es
end

return M
