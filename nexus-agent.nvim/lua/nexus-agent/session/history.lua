--- Conversation history storage for nexus-agent.nvim
--- Persists message arrays alongside session records.

---@class nexus.SessionHistory
---@field _store nexus.SessionStore
local History = {}
History.__index = History

--- Create a new History instance.
---@param store nexus.SessionStore
---@return nexus.SessionHistory
function History:new(store)
  return setmetatable({ _store = store }, self)
end

--- Write full message history for a session.
---@param session_id string
---@param messages table[] Array of messages
function History:write(session_id, messages)
  local path = self._store._sessions_dir .. "/" .. session_id .. ".history.json"
  vim.fn.writefile({ vim.json.encode(messages) }, path)
end

--- Read message history for a session.
---@param session_id string
---@return table[] Array of messages
function History:read(session_id)
  local path = self._store._sessions_dir .. "/" .. session_id .. ".history.json"
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Append a single message to the history.
---@param session_id string
---@param message table
function History:append(session_id, message)
  local messages = self:read(session_id)
  table.insert(messages, message)
  self:write(session_id, messages)
end

--- Clear the history for a session.
---@param session_id string
function History:clear(session_id)
  local path = self._store._sessions_dir .. "/" .. session_id .. ".history.json"
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

return History
