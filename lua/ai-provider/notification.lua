--- Floating spinner notification for long-running requests.
local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- @class Spinner
--- @field buf number
--- @field win number
--- @field timer uv_timer_t
--- @field frame number
--- @field message string

--- @type Spinner|nil
local active_spinner = nil

--- Build the display line for the current frame.
--- @param frame number
--- @param message string
--- @return string
local function spinner_line(frame, message)
  return " " .. spinner_frames[frame] .. "  " .. message .. " "
end

--- Compute the window width from the message text.
--- @param message string
--- @return number
local function win_width(message)
  -- +5 accounts for: leading space, spinner char, two spaces, trailing space
  return vim.fn.strdisplaywidth(message) + 5
end

--- Show a floating spinner in the top-right corner.
--- @param message string  Text to display next to the spinner
--- @return fun()          Call this function to dismiss the spinner
function M.show(message)
  -- If there is already an active spinner, close it first.
  if active_spinner then
    M.dismiss()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = win_width(message)
  local initial_line = spinner_line(1, message)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial_line })

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = width,
    height = 1,
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
    message = message,
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

      local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { spinner_line(frame, message) })
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
