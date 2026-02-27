--- EventEmitter for nexus-agent.nvim
--- A simple event emitter class with vim.schedule safety.

---@class nexus.EventEmitter
---@field _listeners table<string, function[]>
local EventEmitter = {}
EventEmitter.__index = EventEmitter

--- Create a new EventEmitter instance.
---@return nexus.EventEmitter
function EventEmitter:new()
  return setmetatable({
    _listeners = {},
  }, self)
end

--- Register a callback for an event.
---@param event string
---@param callback function
---@return nexus.EventEmitter self For chaining
function EventEmitter:on(event, callback)
  if not self._listeners[event] then
    self._listeners[event] = {}
  end
  table.insert(self._listeners[event], callback)
  return self
end

--- Remove a specific callback for an event.
---@param event string
---@param callback function
---@return nexus.EventEmitter self For chaining
function EventEmitter:off(event, callback)
  local listeners = self._listeners[event]
  if not listeners then
    return self
  end
  for i = #listeners, 1, -1 do
    if listeners[i] == callback then
      table.remove(listeners, i)
      break
    end
  end
  return self
end

--- Register a callback that fires only once for an event.
---@param event string
---@param callback function
---@return nexus.EventEmitter self For chaining
function EventEmitter:once(event, callback)
  local wrapper
  wrapper = function(...)
    self:off(event, wrapper)
    callback(...)
  end
  return self:on(event, wrapper)
end

--- Emit an event, calling all registered callbacks via vim.schedule.
---@param event string
---@param ... any Arguments passed to callbacks
function EventEmitter:emit(event, ...)
  local listeners = self._listeners[event]
  if not listeners or #listeners == 0 then
    return
  end
  -- Snapshot the listener list to avoid mutation during iteration
  local snapshot = { unpack(listeners) }
  local args = { ... }
  vim.schedule(function()
    for _, cb in ipairs(snapshot) do
      cb(unpack(args))
    end
  end)
end

--- Remove all listeners for a specific event, or all events if nil.
---@param event? string
function EventEmitter:remove_all(event)
  if event then
    self._listeners[event] = nil
  else
    self._listeners = {}
  end
end

return EventEmitter
