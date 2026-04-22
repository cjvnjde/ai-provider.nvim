--- Unicode sanitation helpers.
---
--- Lua strings are byte-sequences, so unlike JavaScript we don't have raw
--- UTF-16 surrogates floating around in normal data. This module keeps
--- pi-mono's API surface (`sanitize_surrogates`) but only tries to strip
--- *encoded* CESU-8 / WTF-8 lone surrogates (0xED 0xA0..0xBF 0x80..0xBF),
--- which some upstream APIs reject.
---
--- Valid emoji (properly paired surrogates encoded as 4-byte UTF-8) are
--- preserved untouched because they never reach the surrogate range once
--- encoded as UTF-8.
local M = {}

--- Remove WTF-8 encoded lone surrogates from `text`.
---@param text string|nil
---@return string
function M.sanitize_surrogates(text)
  if text == nil then return "" end
  if type(text) ~= "string" then return tostring(text) end
  -- 3-byte sequences starting with 0xED that encode code points U+D800..U+DFFF.
  -- Paired surrogates are already encoded as a 4-byte UTF-8 sequence so won't match.
  return (text:gsub("\237[\160-\191][\128-\191]", ""))
end

return M
