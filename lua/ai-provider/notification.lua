--- Floating spinner notification for long-running requests.
local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- @class Spinner
--- @field buf number
--- @field win number
--- @field timer uv_timer_t
--- @field frame number
--- @field lines string[]

--- @type Spinner|nil
local active_spinner = nil

--- Padding for continuation lines (aligned with text after spinner).
local prefix_pad = "    "

--- Build display lines for the current frame.
--- @param frame number
--- @param lines string[]
--- @return string[]
local function build_display(frame, lines)
  local out = {}
  for i, line in ipairs(lines) do
    if i == 1 then
      out[i] = " " .. spinner_frames[frame] .. "  " .. line .. " "
    else
      out[i] = " " .. prefix_pad .. line .. " "
    end
  end
  return out
end

--- Compute the window width from the widest line.
--- @param lines string[]
--- @return number
local function win_width(lines)
  local max = 0
  for i, line in ipairs(lines) do
    -- first line: space + spinner + two spaces + text + trailing space  = +5
    -- other lines: space + 4-char pad + text + trailing space           = +6
    local w = vim.fn.strdisplaywidth(line) + (i == 1 and 5 or 6)
    if w > max then max = w end
  end
  return max
end

--- Show a floating spinner in the top-right corner.
---
--- @param message string|string[]  Single string or list of lines
--- @return fun()                   Call this function to dismiss the spinner
function M.show(message)
  -- If there is already an active spinner, close it first.
  if active_spinner then
    M.dismiss()
  end

  local lines = type(message) == "table" and message or { message }

  local buf = vim.api.nvim_create_buf(false, true)
  local width = win_width(lines)
  local height = #lines

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_display(1, lines))

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 100,
  })

  -- Highlight: use a subtle background so it stands out.
  vim.api.nvim_set_option_value("winhl", "Normal:DiagnosticInfo,FloatBorder:DiagnosticInfo", { win = win })

  local frame = 1
  local timer = vim.uv.new_timer()

  active_spinner = {
    buf = buf,
    win = win,
    timer = timer,
    frame = frame,
    lines = lines,
  }

  timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if not active_spinner or active_spinner.buf ~= buf then
        return
      end

      frame = (frame % #spinner_frames) + 1
      active_spinner.frame = frame

      local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, build_display(frame, lines))
      if not ok then
        -- Buffer was closed externally – clean up.
        M.dismiss()
      end
    end)
  )

  return function()
    M.dismiss()
  end
end

--- Dismiss the active spinner (if any).
function M.dismiss()
  local s = active_spinner
  if not s then
    return
  end

  active_spinner = nil

  if s.timer then
    pcall(function()
      s.timer:stop()
      s.timer:close()
    end)
  end

  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end

  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  end
end

return M
