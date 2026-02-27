--- Builder pattern for creating tool definitions.
--- Produces nexus.ToolDefinition tables with JSON Schema input_schema.
---@class nexus.ToolBuilder
---@field private _name string?
---@field private _description string?
---@field private _params {name: string, type: string, description: string, opts: table}[]
---@field private _handler fun(input: table): string|table|nil
local ToolBuilder = {}
ToolBuilder.__index = ToolBuilder

--- Create a new ToolBuilder instance.
---@return nexus.ToolBuilder
function ToolBuilder:new()
  return setmetatable({
    _name = nil,
    _description = nil,
    _params = {},
    _handler = nil,
  }, self)
end

--- Set the tool name.
---@param n string
---@return nexus.ToolBuilder
function ToolBuilder:name(n)
  self._name = n
  return self
end

--- Set the tool description.
---@param d string
---@return nexus.ToolBuilder
function ToolBuilder:description(d)
  self._description = d
  return self
end

--- Add a parameter to the tool.
---@param name string Parameter name
---@param type string JSON Schema type ("string", "number", "boolean", "array", "object")
---@param description string Parameter description
---@param opts? { required?: boolean, enum?: string[], default?: any } Parameter options (required defaults to true)
---@return nexus.ToolBuilder
function ToolBuilder:param(name, type, description, opts)
  table.insert(self._params, {
    name = name,
    type = type,
    description = description,
    opts = opts or {},
  })
  return self
end

--- Set the tool handler function.
---@param fn fun(input: table): string|table
---@return nexus.ToolBuilder
function ToolBuilder:handler(fn)
  self._handler = fn
  return self
end

--- Build and validate the tool definition.
---@return nexus.ToolDefinition
function ToolBuilder:build()
  assert(self._name, "ToolBuilder: 'name' is required")
  assert(self._description, "ToolBuilder: 'description' is required")
  assert(self._handler, "ToolBuilder: 'handler' is required")

  local properties = {}
  local required = {}

  for _, p in ipairs(self._params) do
    local prop = {
      type = p.type,
      description = p.description,
    }
    if p.opts.enum then
      prop.enum = p.opts.enum
    end
    if p.opts.default ~= nil then
      prop.default = p.opts.default
    end
    properties[p.name] = prop

    -- required defaults to true when not explicitly set to false
    if p.opts.required ~= false then
      table.insert(required, p.name)
    end
  end

  local input_schema = {
    type = "object",
    properties = properties,
  }
  if #required > 0 then
    input_schema.required = required
  end

  return {
    name = self._name,
    description = self._description,
    input_schema = input_schema,
    handler = self._handler,
  }
end

return ToolBuilder
