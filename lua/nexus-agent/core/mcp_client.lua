--- MCP server management for nexus-agent.nvim
--- Registers MCP server configs and builds CLI config payloads.

---@class nexus.MCPServerEntry
---@field config table MCP server config from MCPBuilder
---@field process any|nil Process handle
---@field status "stopped"|"running"|"error"

---@class nexus.MCPClient
---@field _servers table<string, nexus.MCPServerEntry>
local MCPClient = {}
MCPClient.__index = MCPClient

--- Create a new MCPClient instance.
---@return nexus.MCPClient
function MCPClient:new()
  return setmetatable({
    _servers = {},
  }, self)
end

--- Register an MCP server config.
---@param config table Server config with name, command, args, env, cwd fields
function MCPClient:register(config)
  local ok, err = self:validate(config.name, config)
  if not ok then
    error(err)
  end
  self._servers[config.name] = { config = config, process = nil, status = "stopped" }
end

--- Build the --mcp-config JSON payload for the CLI.
---@return string JSON string for the --mcp-config flag
function MCPClient:build_cli_config()
  local mcp_config = { mcpServers = {} }
  for name, server in pairs(self._servers) do
    mcp_config.mcpServers[name] = {
      command = server.config.command,
      args = server.config.args,
      env = server.config.env,
      cwd = server.config.cwd,
    }
  end
  return vim.json.encode(mcp_config)
end

--- Validate an MCP server config.
---@param name string|nil Server name
---@param config table Server config
---@return boolean ok
---@return string|nil error_message
function MCPClient:validate(name, config)
  if not name then
    return false, "MCP server must have a name"
  end
  if not config.command then
    return false, "MCP server must have a command"
  end
  return true, nil
end

--- List all registered servers with their status.
---@return table[] Array of {name, status, config}
function MCPClient:list()
  local result = {}
  for name, server in pairs(self._servers) do
    table.insert(result, { name = name, status = server.status, config = server.config })
  end
  return result
end

--- Get the status of a specific server.
---@param name string Server name
---@return string Status ("stopped", "running", "error", or "unknown")
function MCPClient:status(name)
  local server = self._servers[name]
  return server and server.status or "unknown"
end

--- Check if a server is registered.
---@param name string
---@return boolean
function MCPClient:has(name)
  return self._servers[name] ~= nil
end

return MCPClient
