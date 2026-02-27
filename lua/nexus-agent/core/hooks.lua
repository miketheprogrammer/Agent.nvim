--- Hook system for nexus-agent.nvim
--- Allows registering pre/post tool use hooks and notification handlers.

---@alias nexus.HookEventName "PreToolUse"|"PostToolUse"|"Stop"|"Notification"

---@class nexus.HookMatcher
---@field matcher string|nil Pattern to match against tool_name
---@field handler fun(input: table): string|table|nil Hook handler
---@field timeout number|nil Timeout in milliseconds

---@class nexus.Hooks
---@field _hooks table<nexus.HookEventName, nexus.HookMatcher[]>
local Hooks = {}
Hooks.__index = Hooks

--- Create a new Hooks instance.
---@return nexus.Hooks
function Hooks:new()
  return setmetatable({ _hooks = {} }, self)
end

--- Register a hook for an event.
---@param event nexus.HookEventName
---@param matcher nexus.HookMatcher Hook definition with matcher pattern, handler, and optional timeout
function Hooks:on(event, matcher)
  self._hooks[event] = self._hooks[event] or {}
  table.insert(self._hooks[event], matcher)
end

--- Remove all hooks for an event.
---@param event nexus.HookEventName
function Hooks:off(event)
  self._hooks[event] = nil
end

--- Fire all hooks for an event, returning the first decisive result.
---@param event nexus.HookEventName
---@param input table Hook input with tool_name, tool_input, etc.
---@return string|nil decision "allow", "deny", or nil
---@return table|nil modified_input Modified input table if returned by a hook
function Hooks:fire(event, input)
  local hooks = self._hooks[event]
  if not hooks then
    return nil, nil
  end

  for _, hook in ipairs(hooks) do
    -- Check matcher pattern against tool name
    if not hook.matcher or (input.tool_name and input.tool_name:match(hook.matcher)) then
      local ok, result = pcall(hook.handler, input)
      if ok and result then
        if result == "deny" then
          return "deny", nil
        end
        if result == "allow" then
          return "allow", nil
        end
        if type(result) == "table" then
          return nil, result
        end
      end
    end
  end
  return nil, nil
end

--- Check if any hooks are registered for an event.
---@param event nexus.HookEventName
---@return boolean
function Hooks:has(event)
  return self._hooks[event] ~= nil and #self._hooks[event] > 0
end

--- List all events that have registered hooks.
---@return nexus.HookEventName[]
function Hooks:events()
  local result = {}
  for event, _ in pairs(self._hooks) do
    table.insert(result, event)
  end
  return result
end

return Hooks
