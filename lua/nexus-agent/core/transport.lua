--- SubprocessCLITransport for nexus-agent.nvim
--- Spawns Claude CLI as a subprocess using vim.uv (libuv bindings).
--- Communicates bidirectionally via stdin/stdout using stream-json format.

local uv = vim.uv or vim.loop

---@class nexus.Transport
---@field _stdin uv_pipe_t?
---@field _stdout uv_pipe_t?
---@field _stderr uv_pipe_t?
---@field _process uv_process_t?
---@field _pid integer?
---@field _buffer string Accumulator for partial JSON lines
---@field _callbacks nexus.TransportCallbacks
---@field _state "disconnected"|"connecting"|"connected"|"closing"|"closed"
local Transport = {}
Transport.__index = Transport

--- Create a new Transport instance.
---@param callbacks nexus.TransportCallbacks
---@return nexus.Transport
function Transport:new(callbacks)
  return setmetatable({
    _stdin = nil,
    _stdout = nil,
    _stderr = nil,
    _process = nil,
    _pid = nil,
    _buffer = "",
    _callbacks = callbacks,
    _state = "disconnected",
  }, self)
end

--- Set the transport state and notify via callback.
---@param state string
---@private
function Transport:_set_state(state)
  self._state = state
  if self._callbacks.on_state_change then
    vim.schedule(function()
      self._callbacks.on_state_change(state)
    end)
  end
end

--- Build CLI arguments from options (prompt is sent via stdin, not here).
---@param opts nexus.Config
---@return string[]
---@private
function Transport._build_args(opts)
  local args = {
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--verbose",
  }

  if opts.model then
    args[#args + 1] = "--model"
    args[#args + 1] = opts.model
  end

  if opts.system_prompt then
    args[#args + 1] = "--system-prompt"
    args[#args + 1] = opts.system_prompt
  end

  if opts.permission_mode then
    args[#args + 1] = "--permission-mode"
    args[#args + 1] = opts.permission_mode
  end

  if opts.max_turns then
    args[#args + 1] = "--max-turns"
    args[#args + 1] = tostring(opts.max_turns)
  end

  if opts.mcp_servers and next(opts.mcp_servers) then
    args[#args + 1] = "--mcp-config"
    args[#args + 1] = vim.json.encode(opts.mcp_servers)
  end

  if opts.allowed_tools and #opts.allowed_tools > 0 then
    for _, tool in ipairs(opts.allowed_tools) do
      args[#args + 1] = "--allowed-tools"
      args[#args + 1] = tool
    end
  end

  if opts.session_id then
    args[#args + 1] = "--resume"
    args[#args + 1] = opts.session_id
  end

  return args
end

--- Build environment variable array for libuv spawn.
--- Inherits parent env, applies overrides, and unsets CLAUDECODE to avoid nesting detection.
---@param overrides? table<string, string>
---@return string[]
---@private
function Transport._build_env(overrides)
  local env_map = {}
  for k, v in pairs(vim.fn.environ()) do
    env_map[k] = v
  end
  -- Remove CLAUDECODE to avoid "nested session" error
  env_map["CLAUDECODE"] = nil
  -- Apply overrides
  if overrides then
    for k, v in pairs(overrides) do
      if v == nil then
        env_map[k] = nil
      else
        env_map[k] = v
      end
    end
  end
  -- Convert to KEY=VALUE array for libuv
  local env = {}
  for k, v in pairs(env_map) do
    env[#env + 1] = k .. "=" .. v
  end
  return env
end

--- Process buffered stdout data into JSON messages.
--- Accumulates partial lines and parses complete ones.
---@param chunk string
---@private
function Transport:_process_stdout(chunk)
  self._buffer = self._buffer .. chunk

  local lines = vim.split(self._buffer, "\n", { plain = true })
  -- Last element is either empty (if chunk ended with \n) or a partial line
  self._buffer = lines[#lines]

  for i = 1, #lines - 1 do
    local line = vim.trim(lines[i])
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and msg then
        vim.schedule(function()
          self._callbacks.on_message(msg)
        end)
      end
    end
  end
end

--- Spawn the Claude CLI subprocess and establish pipes.
--- The initial prompt is sent via stdin after the process starts.
---@param prompt string The initial prompt to send
---@param opts nexus.Config Configuration options
function Transport:connect(prompt, opts)
  if self._state == "connected" or self._state == "connecting" then
    return
  end

  self:_set_state("connecting")

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local args = self._build_args(opts)
  local env = self._build_env(opts.env)
  local cli_path = opts.cli_path or "claude"

  local handle, pid = uv.spawn(cli_path, {
    args = args,
    env = env,
    stdio = { stdin, stdout, stderr },
    detached = false,
    cwd = opts.cwd,
  }, function(code, _signal)
    vim.schedule(function()
      self:_set_state("closed")
      self._callbacks.on_exit(code)
    end)
  end)

  if not handle then
    self:_set_state("disconnected")
    -- Close pipes we created
    stdin:close()
    stdout:close()
    stderr:close()
    vim.schedule(function()
      self._callbacks.on_exit(-1)
    end)
    return
  end

  self._stdin = stdin
  self._stdout = stdout
  self._stderr = stderr
  self._process = handle
  self._pid = pid

  -- Read stdout: line-buffered JSON parsing
  stdout:read_start(function(err, data)
    if err then return end
    if data then
      self:_process_stdout(data)
    end
  end)

  -- Read stderr: pass to callback
  stderr:read_start(function(err, data)
    if err then return end
    if data and self._callbacks.on_stderr then
      vim.schedule(function()
        self._callbacks.on_stderr(data)
      end)
    end
  end)

  self:_set_state("connected")

  -- Send the initial prompt via stdin as stream-json
  if prompt and prompt ~= "" then
    self:send(prompt)
  end
end

--- Send a user message to the subprocess via stdin.
--- Uses the stream-json wire format: {type, message, session_id, parent_tool_use_id}
---@param message string The user message text
---@param session_id? string Session ID for multi-turn continuity
function Transport:send(message, session_id)
  self:write({
    type = "user",
    message = {
      role = "user",
      content = message,
    },
    session_id = session_id or vim.NIL,
    parent_tool_use_id = vim.NIL,
  })
end

--- Write raw JSON data to the subprocess stdin.
---@param data table Data to encode and send as newline-delimited JSON
function Transport:write(data)
  if not self._stdin or self._stdin:is_closing() then
    return
  end
  local encoded = vim.json.encode(data) .. "\n"
  self._stdin:write(encoded)
end

--- Close stdin to signal end of input (process may finish naturally).
function Transport:end_input()
  if self._stdin and not self._stdin:is_closing() then
    self._stdin:close()
    self._stdin = nil
  end
end

--- Close the transport and kill the subprocess.
function Transport:close()
  if self._state == "closing" or self._state == "closed" then
    return
  end
  self:_set_state("closing")

  -- Stop reading
  if self._stdout and not self._stdout:is_closing() then
    self._stdout:read_stop()
    self._stdout:close()
  end
  if self._stderr and not self._stderr:is_closing() then
    self._stderr:read_stop()
    self._stderr:close()
  end
  if self._stdin and not self._stdin:is_closing() then
    self._stdin:close()
  end

  -- Kill process: try SIGTERM, then force SIGKILL after a delay
  if self._process and not self._process:is_closing() then
    self._process:kill("sigterm")
    local timer = uv.new_timer()
    local process = self._process
    timer:start(2000, 0, function()
      timer:close()
      if process and not process:is_closing() then
        process:kill("sigkill")
      end
    end)
  end

  self._stdin = nil
  self._stdout = nil
  self._stderr = nil
end

--- Check if the transport is currently active.
---@return boolean
function Transport:is_active()
  return self._state == "connected"
end

return Transport
