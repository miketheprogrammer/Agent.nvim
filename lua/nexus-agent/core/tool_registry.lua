--- Tool registry for nexus-agent.nvim
--- Stores and executes tool definitions by name.

---@class nexus.ToolRegistry
---@field _tools table<string, nexus.ToolDefinition>
local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

--- Create a new ToolRegistry instance.
---@return nexus.ToolRegistry
function ToolRegistry:new()
  return setmetatable({ _tools = {} }, self)
end

--- Register a tool definition.
---@param def nexus.ToolDefinition Tool definition with name, description, input_schema, handler
function ToolRegistry:register(def)
  assert(def.name, "Tool must have a name")
  assert(def.handler, "Tool must have a handler function")
  self._tools[def.name] = def
end

--- Register multiple tool definitions.
---@param defs nexus.ToolDefinition[]
function ToolRegistry:register_all(defs)
  for _, def in ipairs(defs) do
    self:register(def)
  end
end

--- Get a tool definition by name.
---@param name string
---@return nexus.ToolDefinition|nil
function ToolRegistry:get(name)
  return self._tools[name]
end

--- List all registered tool names (sorted).
---@return string[]
function ToolRegistry:list()
  local names = {}
  for name, _ in pairs(self._tools) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- List all tool definitions.
---@return nexus.ToolDefinition[]
function ToolRegistry:list_defs()
  local defs = {}
  for _, def in pairs(self._tools) do
    table.insert(defs, def)
  end
  return defs
end

--- Execute a tool by name with the given arguments.
---@param name string Tool name
---@param args table Tool input arguments
---@return table Result with content and optional is_error
function ToolRegistry:execute(name, args)
  local tool = self._tools[name]
  if not tool then
    return { content = { { type = "text", text = "Tool not found: " .. name } }, is_error = true }
  end
  local ok, result = pcall(tool.handler, args)
  if not ok then
    return { content = { { type = "text", text = "Tool error: " .. tostring(result) } }, is_error = true }
  end
  -- Normalize result into standard content format
  if type(result) == "string" then
    result = { content = { { type = "text", text = result } } }
  elseif type(result) == "table" and result.content and type(result.content) == "string" then
    result = { content = { { type = "text", text = result.content } } }
  end
  return result
end

--- Check if a tool is registered.
---@param name string
---@return boolean
function ToolRegistry:has(name)
  return self._tools[name] ~= nil
end

return ToolRegistry
