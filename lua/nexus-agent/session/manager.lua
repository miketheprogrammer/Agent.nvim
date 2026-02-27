--- Session lifecycle manager for nexus-agent.nvim
--- Creates, resumes, forks, and manages active sessions.

---@class nexus.SessionManager
---@field _store nexus.SessionStore
---@field _history nexus.SessionHistory
---@field _events nexus.EventEmitter
---@field _active table|nil Current active session
local Manager = {}
Manager.__index = Manager

--- Create a new SessionManager instance.
---@param opts? { cache_dir?: string }
---@return nexus.SessionManager
function Manager:new(opts)
  opts = opts or {}
  local store = require("nexus-agent.session.store"):new(opts.cache_dir)
  local history = require("nexus-agent.session.history"):new(store)
  local events = require("nexus-agent.events"):new()
  return setmetatable({
    _store = store,
    _history = history,
    _events = events,
    _active = nil,
  }, self)
end

--- Generate a UUID v4-like session ID.
---@return string
---@private
function Manager:_generate_id()
  math.randomseed(os.time() + math.floor(os.clock() * 1000))
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

--- Create a new session.
---@param agent_config table Agent configuration with name, model fields
---@return table Session object
function Manager:create(agent_config)
  local id = self:_generate_id()
  local session = {
    session_id = id,
    agent = agent_config.name,
    model = agent_config.model or "sonnet",
    prompt = "",
    timestamp = os.time(),
    duration_ms = 0,
    num_turns = 0,
    messages = {},
    status = "created",
  }
  self._active = session
  self._events:emit("session:created", session)
  return session
end

--- Resume an existing session by loading it from store.
---@param session_id string
---@param prompt? string Optional new prompt to continue with
---@return table|nil Session object or nil if not found
function Manager:resume(session_id, prompt)
  local record = self._store:load(session_id)
  if not record then
    return nil
  end
  record.messages = self._history:read(session_id)
  record.status = "resumed"
  if prompt then
    record.prompt = prompt
  end
  self._active = record
  self._events:emit("session:resumed", record)
  return record
end

--- Fork a session by creating a new one from an existing session's history.
---@param session_id string Source session ID
---@return table|nil New session or nil if source not found
function Manager:fork(session_id)
  local source = self._store:load(session_id)
  if not source then
    return nil
  end
  local id = self:_generate_id()
  local session = {
    session_id = id,
    agent = source.agent,
    model = source.model,
    prompt = "",
    timestamp = os.time(),
    duration_ms = 0,
    num_turns = 0,
    messages = self._history:read(session_id),
    status = "created",
    forked_from = session_id,
  }
  self._active = session
  self._events:emit("session:forked", session)
  return session
end

--- List all sessions from the store.
---@return table[] Array of session summaries
function Manager:list()
  return self._store:list()
end

--- Get a specific session by ID.
---@param session_id string
---@return table|nil
function Manager:get(session_id)
  return self._store:load(session_id)
end

--- Save the current active session with an optional result message.
---@param result_msg? table Optional result message to finalize the session
function Manager:save_active(result_msg)
  if not self._active then
    return
  end
  if result_msg then
    self._active.duration_ms = result_msg.duration_ms or self._active.duration_ms
    self._active.num_turns = result_msg.num_turns or self._active.num_turns
    self._active.total_cost_usd = result_msg.cost_usd or self._active.total_cost_usd
    self._active.status = result_msg.is_error and "error" or "completed"
  end
  self._store:save(self._active)
  if self._active.messages and #self._active.messages > 0 then
    self._history:write(self._active.session_id, self._active.messages)
  end
  self._events:emit("session:saved", self._active)
end

--- Get the current active session.
---@return table|nil
function Manager:active()
  return self._active
end

--- Subscribe to session events.
---@param event string Event name (e.g. "session:created", "session:saved")
---@param callback function
function Manager:on(event, callback)
  self._events:on(event, callback)
end

return Manager
