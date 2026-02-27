--- Builder for composing structured system prompts.
--- Produces formatted markdown strings with role, context, rules, format, and examples sections.
---@class nexus.InstructionBuilder
---@field private _role string?
---@field private _context string[]
---@field private _rules string[]
---@field private _formats string[]
---@field private _examples string[]
local InstructionBuilder = {}
InstructionBuilder.__index = InstructionBuilder

--- Create a new InstructionBuilder instance.
---@return nexus.InstructionBuilder
function InstructionBuilder:new()
  return setmetatable({
    _role = nil,
    _context = {},
    _rules = {},
    _formats = {},
    _examples = {},
  }, self)
end

--- Set the role description.
---@param r string
---@return nexus.InstructionBuilder
function InstructionBuilder:role(r)
  self._role = r
  return self
end

--- Add a context item.
---@param c string
---@return nexus.InstructionBuilder
function InstructionBuilder:context(c)
  table.insert(self._context, c)
  return self
end

--- Add a rule.
---@param r string
---@return nexus.InstructionBuilder
function InstructionBuilder:rule(r)
  table.insert(self._rules, r)
  return self
end

--- Add an output format guideline.
---@param f string
---@return nexus.InstructionBuilder
function InstructionBuilder:format(f)
  table.insert(self._formats, f)
  return self
end

--- Add an example.
---@param e string
---@return nexus.InstructionBuilder
function InstructionBuilder:example(e)
  table.insert(self._examples, e)
  return self
end

--- Build the formatted system prompt string.
--- Omits sections that have no content.
---@return string
function InstructionBuilder:build()
  local parts = {}

  if self._role then
    table.insert(parts, "# Role\n" .. self._role)
  end

  if #self._context > 0 then
    local lines = { "# Context" }
    for _, c in ipairs(self._context) do
      table.insert(lines, "- " .. c)
    end
    table.insert(parts, table.concat(lines, "\n"))
  end

  if #self._rules > 0 then
    local lines = { "# Rules" }
    for _, r in ipairs(self._rules) do
      table.insert(lines, "- " .. r)
    end
    table.insert(parts, table.concat(lines, "\n"))
  end

  if #self._formats > 0 then
    local lines = { "# Output Format" }
    for _, f in ipairs(self._formats) do
      table.insert(lines, "- " .. f)
    end
    table.insert(parts, table.concat(lines, "\n"))
  end

  if #self._examples > 0 then
    local lines = { "# Examples" }
    for _, e in ipairs(self._examples) do
      table.insert(lines, e)
    end
    table.insert(parts, table.concat(lines, "\n"))
  end

  return table.concat(parts, "\n\n")
end

return InstructionBuilder
