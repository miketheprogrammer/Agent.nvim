local Status = {}
Status.__index = Status

local _instance = nil

function Status.get_instance()
  if not _instance then
    _instance = setmetatable({
      _state = "idle",
      _agent_name = nil,
      _turns = 0,
      _cost = 0,
    }, Status)
  end
  return _instance
end

--- Set the current state
function Status:set_state(state, info)
  self._state = state
  if info then
    self._agent_name = info.agent_name or self._agent_name
    self._turns = info.turns or self._turns
    self._cost = info.cost or self._cost
  end
  -- Trigger statusline refresh
  vim.cmd("redrawstatus")
end

--- Get formatted status string
function Status:get()
  local icons = {
    idle = "○",
    thinking = "◉",
    streaming = "◈",
    tool_use = "◆",
    error = "✗",
    complete = "✓",
  }
  local icon = icons[self._state] or "○"
  local name = self._agent_name or "nexus"

  if self._state == "idle" then
    return icon .. " " .. name
  elseif self._state == "thinking" then
    return icon .. " " .. name .. ": thinking..."
  elseif self._state == "streaming" then
    return icon .. " " .. name .. ": streaming..."
  elseif self._state == "tool_use" then
    return icon .. " " .. name .. ": using tool..."
  elseif self._state == "error" then
    return icon .. " " .. name .. ": error"
  elseif self._state == "complete" then
    local cost_str = self._cost > 0 and string.format(" ($%.3f)", self._cost) or ""
    return icon .. " " .. name .. ": done" .. cost_str
  end
  return icon .. " " .. name
end

--- Lualine-compatible component function
function Status.component()
  return function()
    return Status.get_instance():get()
  end
end

--- Reset state
function Status:reset()
  self._state = "idle"
  self._agent_name = nil
  self._turns = 0
  self._cost = 0
end

return Status
