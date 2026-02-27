--- Control Protocol for nexus-agent.nvim
--- Request/response tracking with ID generation and timeout management.

local uv = vim.uv or vim.loop

local DEFAULT_TIMEOUT_MS = 30000

---@class nexus.PendingRequest
---@field callback fun(result: table)
---@field timestamp integer

---@class nexus.Protocol
---@field _next_id integer
---@field _pending table<integer, nexus.PendingRequest>
---@field _timeout_ms integer
---@field _timer uv_timer_t?
local Protocol = {}
Protocol.__index = Protocol

--- Create a new Protocol instance.
---@param opts? { timeout_ms?: integer }
---@return nexus.Protocol
function Protocol:new(opts)
  opts = opts or {}
  local instance = setmetatable({
    _next_id = 1,
    _pending = {},
    _timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
    _timer = nil,
  }, self)
  instance:_start_timeout_sweep()
  return instance
end

--- Generate the next unique request ID.
---@return integer
---@private
function Protocol:_gen_id()
  local id = self._next_id
  self._next_id = self._next_id + 1
  return id
end

--- Start the periodic timeout sweep timer.
---@private
function Protocol:_start_timeout_sweep()
  if self._timer then
    return
  end
  self._timer = uv.new_timer()
  self._timer:start(5000, 5000, function()
    vim.schedule(function()
      self:_sweep_timeouts()
    end)
  end)
end

--- Sweep pending requests for timeouts.
---@private
function Protocol:_sweep_timeouts()
  local now = uv.now()
  local timed_out = {}

  for id, req in pairs(self._pending) do
    if (now - req.timestamp) > self._timeout_ms then
      timed_out[#timed_out + 1] = id
    end
  end

  for _, id in ipairs(timed_out) do
    local req = self._pending[id]
    self._pending[id] = nil
    if req and req.callback then
      req.callback({ error = "request_timeout", id = id })
    end
  end
end

--- Create a request message.
---@param method string The method name
---@param params? table Optional parameters
---@return integer id The request ID
---@return table message The formatted request message
function Protocol:request(method, params)
  local id = self:_gen_id()
  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }
  return id, message
end

--- Register a callback for a pending request.
---@param id integer The request ID
---@param callback fun(result: table)
function Protocol:on_response(id, callback)
  self._pending[id] = {
    callback = callback,
    timestamp = uv.now(),
  }
end

--- Create a response message.
---@param id integer The request ID being responded to
---@param result table The result data
---@return table message The formatted response message
function Protocol:response(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result,
  }
end

--- Handle an incoming message, routing responses to pending callbacks.
---@param message table The received message
---@return boolean handled Whether the message was a response that was handled
function Protocol:handle(message)
  -- Only handle response messages (those with an id and result/error, but no method)
  if not message.id or message.method then
    return false
  end

  local req = self._pending[message.id]
  if not req then
    return false
  end

  self._pending[message.id] = nil

  if req.callback then
    local result = message.result or message.error or message
    req.callback(result)
  end

  return true
end

--- Check if there are any pending requests.
---@return boolean
function Protocol:has_pending()
  return next(self._pending) ~= nil
end

--- Get the count of pending requests.
---@return integer
function Protocol:pending_count()
  local count = 0
  for _ in pairs(self._pending) do
    count = count + 1
  end
  return count
end

--- Stop the timeout sweep and clean up.
function Protocol:destroy()
  if self._timer and not self._timer:is_closing() then
    self._timer:stop()
    self._timer:close()
  end
  self._timer = nil
  self._pending = {}
end

return Protocol
