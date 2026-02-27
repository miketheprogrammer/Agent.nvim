--- Builder for MCP (Model Context Protocol) server configurations.
--- Produces config tables compatible with Claude CLI --mcp-config JSON structure.
---@class nexus.MCPBuilder
---@field private _name string?
---@field private _command string?
---@field private _args string[]
---@field private _env table<string, string>
---@field private _cwd string?
local MCPBuilder = {}
MCPBuilder.__index = MCPBuilder

--- Create a new MCPBuilder instance.
---@return nexus.MCPBuilder
function MCPBuilder:new()
  return setmetatable({
    _name = nil,
    _command = nil,
    _args = {},
    _env = {},
    _cwd = nil,
  }, self)
end

--- Set the server name.
---@param n string
---@return nexus.MCPBuilder
function MCPBuilder:name(n)
  self._name = n
  return self
end

--- Set the server command.
---@param c string
---@return nexus.MCPBuilder
function MCPBuilder:command(c)
  self._command = c
  return self
end

--- Set the full args list (replaces any existing args).
---@param a string[]
---@return nexus.MCPBuilder
function MCPBuilder:args(a)
  self._args = a
  return self
end

--- Append a single argument.
---@param a string
---@return nexus.MCPBuilder
function MCPBuilder:arg(a)
  table.insert(self._args, a)
  return self
end

--- Merge environment variables into the existing env table.
---@param e table<string, string>
---@return nexus.MCPBuilder
function MCPBuilder:env(e)
  self._env = vim.tbl_extend("force", self._env, e)
  return self
end

--- Set the working directory.
---@param c string
---@return nexus.MCPBuilder
function MCPBuilder:cwd(c)
  self._cwd = c
  return self
end

--- Build and validate the MCP server configuration.
---@return { name: string, command: string, args: string[], env: table<string, string>, cwd: string? }
function MCPBuilder:build()
  assert(self._name, "MCPBuilder: 'name' is required")
  assert(self._command, "MCPBuilder: 'command' is required")

  return {
    name = self._name,
    command = self._command,
    args = self._args,
    env = self._env,
    cwd = self._cwd,
  }
end

return MCPBuilder
