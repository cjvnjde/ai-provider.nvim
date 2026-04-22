--- Fast deterministic hash to shorten long strings.
--- Mirrors pi-mono packages/ai/src/utils/hash.ts (xmur3-style).
---
--- Returns an 8–13 char base-36 string that's stable across runs for the
--- same input. Used to derive shortened tool-call IDs for providers that
--- require short IDs (Mistral, OpenAI Responses normalisation).
local M = {}

-- Match JS Math.imul: signed 32-bit integer multiplication.
local function imul(a, b)
  a = a % 0x100000000
  b = b % 0x100000000
  local ah, al = math.floor(a / 0x10000), a % 0x10000
  local bh, bl = math.floor(b / 0x10000), b % 0x10000
  -- (ah * bl + al * bh) ignores overflow into the high word, matching Math.imul.
  local high = (ah * bl + al * bh) % 0x10000
  local r = (high * 0x10000 + al * bl) % 0x100000000
  return r
end

-- Logical right shift.
local function ushr(a, n)
  a = a % 0x100000000
  return math.floor(a / (2 ^ n))
end

local function bxor32(a, b)
  return (require "bit").bxor(a % 0x100000000, b % 0x100000000) % 0x100000000
end

-- Fall back to a pure-Lua xor if `bit` is unavailable (rare in Neovim).
local ok_bit = pcall(require, "bit")
if not ok_bit then
  bxor32 = function(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local ab = a % 2
      local bb = b % 2
      if ab ~= bb then r = r + p end
      a = (a - ab) / 2
      b = (b - bb) / 2
      p = p * 2
    end
    return r
  end
end

local function tobase36(n)
  if n == 0 then return "0" end
  local s = ""
  while n > 0 do
    local d = n % 36
    if d < 10 then
      s = string.char(48 + d) .. s
    else
      s = string.char(87 + d) .. s -- 'a'..'z'
    end
    n = math.floor(n / 36)
  end
  return s
end

--- Compute a short deterministic hash of the input string.
---@param s string
---@return string  hex-ish base-36 digest
function M.short_hash(s)
  local h1 = 0xdeadbeef
  local h2 = 0x41c6ce57
  for i = 1, #s do
    local ch = string.byte(s, i)
    h1 = imul(bxor32(h1, ch), 2654435761)
    h2 = imul(bxor32(h2, ch), 1597334677)
  end
  h1 = bxor32(imul(bxor32(h1, ushr(h1, 16)), 2246822507), imul(bxor32(h2, ushr(h2, 13)), 3266489909))
  h2 = bxor32(imul(bxor32(h2, ushr(h2, 16)), 2246822507), imul(bxor32(h1, ushr(h1, 13)), 3266489909))
  return tobase36(h2 % 0x100000000) .. tobase36(h1 % 0x100000000)
end

return M
