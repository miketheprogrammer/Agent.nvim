--- Public API for nexus-agent.nvim builder pattern.
--- Provides factory functions for creating builders and forwarding setup.
local M = {}

--- Create a new AgentBuilder.
---@return nexus.AgentBuilder
function M.agent()
  return require("nexus-agent.builder.agent"):new()
end

--- Create a new ToolBuilder.
---@return nexus.ToolBuilder
function M.tool()
  return require("nexus-agent.builder.tool"):new()
end

--- Create a new MCPBuilder.
---@return nexus.MCPBuilder
function M.mcp()
  return require("nexus-agent.builder.mcp"):new()
end

--- Create a new InstructionBuilder.
---@return nexus.InstructionBuilder
function M.instructions()
  return require("nexus-agent.builder.instruction"):new()
end

--- Get the global block type registry.
---@return nexus.BlockRegistry
function M.blocks()
  return require("nexus-agent.core.block_registry").get_instance()
end

--- Forward setup to the main init module.
---@param opts nexus.Config
function M.setup(opts)
  return require("nexus-agent").setup(opts)
end

return M
