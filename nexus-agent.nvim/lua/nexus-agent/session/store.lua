--- File-based session storage for nexus-agent.nvim
--- Persists session records as JSON files in ~/.cache/nvim/nexus-agent/sessions/

---@class nexus.SessionStore
---@field _dir string Base cache directory
---@field _sessions_dir string Sessions subdirectory
local Store = {}
Store.__index = Store

--- Create a new Store instance.
---@param cache_dir? string Override cache directory
---@return nexus.SessionStore
function Store:new(cache_dir)
  local dir = cache_dir or (vim.fn.expand("~") .. "/.cache/nvim/nexus-agent")
  local sessions_dir = dir .. "/sessions"
  vim.fn.mkdir(sessions_dir, "p")
  return setmetatable({
    _dir = dir,
    _sessions_dir = sessions_dir,
  }, self)
end

--- Save a session record to disk.
---@param record table Session record with session_id, agent, model, prompt, timestamp, duration_ms, total_cost_usd, num_turns, result
function Store:save(record)
  assert(record.session_id, "Session record must have a session_id")
  local path = self._sessions_dir .. "/" .. record.session_id .. ".json"
  local encoded = vim.json.encode(record)
  vim.fn.writefile({ encoded }, path)
  self:_update_index()
end

--- Load a session record by ID.
---@param session_id string
---@return table|nil
function Store:load(session_id)
  local path = self._sessions_dir .. "/" .. session_id .. ".json"
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end
  return data
end

--- List all sessions sorted by timestamp descending.
---@return table[] Array of session summaries
function Store:list()
  local index_path = self._dir .. "/index.json"
  if vim.fn.filereadable(index_path) == 1 then
    local content = table.concat(vim.fn.readfile(index_path), "\n")
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
      return data
    end
  end
  -- Fallback: rebuild from session files
  return self:_rebuild_index()
end

--- Delete a session by ID.
---@param session_id string
function Store:delete(session_id)
  local path = self._sessions_dir .. "/" .. session_id .. ".json"
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
  -- Also remove history file if present
  local history_path = self._sessions_dir .. "/" .. session_id .. ".history.json"
  if vim.fn.filereadable(history_path) == 1 then
    vim.fn.delete(history_path)
  end
  self:_update_index()
end

--- Rebuild and persist the index from all session files.
---@return table[] Sorted session summaries
---@private
function Store:_rebuild_index()
  local sessions = {}
  local glob_pattern = self._sessions_dir .. "/*.json"
  local files = vim.fn.glob(glob_pattern, false, true)
  for _, file in ipairs(files) do
    local basename = vim.fn.fnamemodify(file, ":t")
    -- Skip history files and the index
    if not basename:match("%.history%.json$") and basename ~= "index.json" then
      local content = table.concat(vim.fn.readfile(file), "\n")
      local ok, data = pcall(vim.json.decode, content)
      if ok and data then
        table.insert(sessions, {
          session_id = data.session_id,
          agent = data.agent,
          model = data.model,
          prompt = data.prompt,
          timestamp = data.timestamp,
          duration_ms = data.duration_ms,
          num_turns = data.num_turns,
          status = data.status,
        })
      end
    end
  end
  table.sort(sessions, function(a, b)
    return (a.timestamp or 0) > (b.timestamp or 0)
  end)
  return sessions
end

--- Update the index file with current session summaries.
---@private
function Store:_update_index()
  local sessions = self:_rebuild_index()
  local index_path = self._dir .. "/index.json"
  vim.fn.writefile({ vim.json.encode(sessions) }, index_path)
end

--- Get the base cache directory path.
---@return string
function Store:path()
  return self._dir
end

return Store
