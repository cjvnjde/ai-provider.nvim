--- Internal configuration store for ai-provider.
local M = {}

---@class AiProviderConfig
---@field providers table<string, table> Provider-specific settings
M._config = {
  providers = {},
}

--- Merge user options into the global config.
---@param opts? AiProviderConfig
function M.setup(opts)
  if opts then
    M._config = vim.tbl_deep_extend("force", M._config, opts)
  end
end

--- Return the full config table.
function M.get()
  return M._config
end

--- Return config for a single provider.
---@param provider_name string
---@return table
function M.get_provider_config(provider_name)
  return M._config.providers[provider_name] or {}
end

return M
