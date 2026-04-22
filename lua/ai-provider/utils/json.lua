--- Partial / streaming JSON parser.
---
--- Mirrors pi-mono packages/ai/src/utils/json-parse.ts. Used to parse
--- tool-call argument JSON that may still be incomplete while streaming.
--- Always returns a table; never throws. Best-effort.
local M = {}

--- Strict JSON parse via vim.json.decode, returning (ok, value).
---@param json string
---@return boolean ok
---@return any value
local function try_strict(json)
  local ok, res = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  return ok, res
end

-- Repair malformed JSON string literals (escape raw control chars,
-- double-backslash invalid escapes). Mirrors pi-mono's repairJson().
local VALID_ESCAPES = { ['"'] = true, ["\\"] = true, ["/"] = true,
  b = true, f = true, n = true, r = true, t = true, u = true }

local function is_control(b) return b < 0x20 end

local function escape_control(b)
  if b == 0x08 then return "\\b" end
  if b == 0x0c then return "\\f" end
  if b == 0x0a then return "\\n" end
  if b == 0x0d then return "\\r" end
  if b == 0x09 then return "\\t" end
  return string.format("\\u%04x", b)
end

function M.repair_json(json)
  local out = {}
  local in_string = false
  local i = 1
  local n = #json
  while i <= n do
    local c = json:sub(i, i)
    local byte = json:byte(i)
    if not in_string then
      out[#out + 1] = c
      if c == '"' then in_string = true end
      i = i + 1
    else
      if c == '"' then
        out[#out + 1] = c; in_string = false; i = i + 1
      elseif c == "\\" then
        local nc = json:sub(i + 1, i + 1)
        if nc == "" then
          out[#out + 1] = "\\\\"; i = i + 1
        elseif nc == "u" then
          local hex = json:sub(i + 2, i + 5)
          if hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
            out[#out + 1] = "\\u" .. hex; i = i + 6
          else
            out[#out + 1] = "\\\\"; i = i + 1
          end
        elseif VALID_ESCAPES[nc] then
          out[#out + 1] = "\\" .. nc; i = i + 2
        else
          out[#out + 1] = "\\\\"; i = i + 1
        end
      elseif is_control(byte) then
        out[#out + 1] = escape_control(byte); i = i + 1
      else
        out[#out + 1] = c; i = i + 1
      end
    end
  end
  return table.concat(out)
end

-- Brute-force completion of a partially-streamed JSON value:
-- balances braces/brackets and closes open strings. Returns a list of
-- candidate completions to try, from most to least aggressive.
local function candidate_completions(s)
  local out = {}
  local stack = {}
  local in_string = false
  local escape = false
  for i = 1, #s do
    local c = s:sub(i, i)
    out[#out + 1] = c
    if in_string then
      if escape then escape = false
      elseif c == "\\" then escape = true
      elseif c == '"' then in_string = false end
    else
      if c == '"' then in_string = true
      elseif c == "{" then stack[#stack + 1] = "{"
      elseif c == "[" then stack[#stack + 1] = "["
      elseif c == "}" or c == "]" then stack[#stack] = nil end
    end
  end

  local function close_with(tail)
    local chunks = { tail }
    for i = #stack, 1, -1 do
      chunks[#chunks + 1] = (stack[i] == "{") and "}" or "]"
    end
    return table.concat(chunks)
  end

  -- Starting tail: optionally close any open string.
  local base = table.concat(out)
  if in_string then
    if escape then base = base .. "\\" end
    base = base .. '"'
  end

  -- Produce candidates by progressively trimming the tail.
  local candidates = {}
  local seen = {}
  local function add(c)
    if c and not seen[c] then seen[c] = true; candidates[#candidates + 1] = close_with(c) end
  end

  add(base)
  local cur = base
  for _ = 1, 16 do
    local new = cur
    new = new:gsub(",%s*$", "")          -- trailing comma
    if new == cur then new = cur:gsub(":%s*$", "") end                -- orphan colon
    if new == cur then new = cur:gsub('"[^"\\]*"%s*$', "") end       -- orphan bare string (incomplete key or value)
    if new == cur then new = cur:gsub("[%-%+]?%d+%.?%d*[eE]?[%-%+]?%d*%s*$", "") end -- dangling number
    if new == cur then break end
    cur = new
    add(cur)
  end
  return candidates
end

--- Attempt to parse `partial` (possibly incomplete JSON) into a Lua table.
--- Always returns a table. Never throws. Empty result is `vim.empty_dict()`
--- so a subsequent `vim.json.encode` produces `{}` (not `[]`).
---@param partial string|nil
---@return table
function M.parse_streaming_json(partial)
  if not partial or partial == "" then return vim.empty_dict() end
  local trimmed = partial:match("^%s*(.-)%s*$")
  if trimmed == "" then return vim.empty_dict() end

  local ok, val = try_strict(partial)
  if ok and type(val) == "table" then return val end

  local repaired = M.repair_json(partial)
  if repaired ~= partial then
    ok, val = try_strict(repaired)
    if ok and type(val) == "table" then return val end
  end

  local best = vim.empty_dict()
  for _, candidate in ipairs(candidate_completions(partial)) do
    ok, val = try_strict(candidate)
    if ok and type(val) == "table" then return val end
  end

  for _, candidate in ipairs(candidate_completions(repaired)) do
    ok, val = try_strict(candidate)
    if ok and type(val) == "table" then return val end
  end

  return best
end
--- Encode a Lua value as JSON, guaranteeing that an empty-table value is
--- serialised as `{}` rather than `[]`. Used for tool-call arguments,
--- where the API expects an empty object, never an empty array.
---@param v any
---@return string
function M.encode_object(v)
  if type(v) == "table" and next(v) == nil then
    return "{}"
  end
  return vim.json.encode(v)
end

return M
