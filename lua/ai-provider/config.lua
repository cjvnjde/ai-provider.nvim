--- Internal configuration store for ai-provider.
local M = {}

---@class AiProviderConfig
---@field providers table<string, table>  Provider-specific settings
---@field reasoning? string               Default reasoning level: "minimal"|"low"|"medium"|"high"
---@field custom_models? table            Custom model definitions keyed by provider
M._config = {
  providers = {},
  reasoning = nil,       -- nil = no reasoning by default
  custom_models = nil,   -- { provider_name = { model1, model2, ... }, ... }
}

--- Merge user options into the global config.
---@param opts? AiProviderConfig
function M.setup(opts)
  if opts then
    M._config = vim.tbl_deep_extend("force", M._config, opts)

    -- If custom models were provided, merge them into the model registry
    if opts.custom_models then
      local models = require "ai-provider.models"
      for provider, model_list in pairs(opts.custom_models) do
        if not models[provider] then models[provider] = {} end
        for _, model in ipairs(model_list) do
          table.insert(models[provider], model)
        end
        models.invalidate_index()
      end
    end
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
