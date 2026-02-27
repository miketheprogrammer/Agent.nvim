--- Builder for composing agent configurations.
--- Combines tools, instructions, MCP servers, and hooks into a runnable Agent.
local types = require("nexus-agent.types")

--- Agent instance returned by AgentBuilder:build().
---@class nexus.Agent
---@field name string
---@field description string?
---@field model string?
---@field system_prompt string?
---@field tools nexus.ToolDefinition[]
---@field mcp_servers { name: string, command: string, args: string[], env: table<string, string>, cwd: string? }[]
---@field permission_mode nexus.PermissionMode?
---@field max_turns integer?
---@field hooks table<nexus.HookEvent, fun(...)[]>
---@field cwd string?
---@field allowed_tools string[]
local Agent = {}
Agent.__index = Agent

--- Run the agent with a prompt via the transport layer.
---@param prompt string The user prompt to send
---@param opts? { on_message?: fun(msg: nexus.Message), on_text?: fun(text: string), on_thinking?: fun(text: string), on_block_start?: fun(info: table), on_block_stop?: fun(index: number), on_tool_use?: fun(block: nexus.ToolUseBlock), on_tool_call?: fun(name: string, input: table), on_result?: fun(msg: nexus.ResultMessage), on_complete?: fun(msg: nexus.ResultMessage), on_error?: fun(err: string) } Event callbacks
---@return table session_handle A handle with :stop() and :on() methods
function Agent:run(prompt, opts)
  opts = opts or {}
  local Transport = require("nexus-agent.core.transport")
  local message_parser = require("nexus-agent.core.message_parser")
  local EventEmitter = require("nexus-agent.events")

  local emitter = EventEmitter:new()
  local handle = { _transport = nil, _emitter = emitter }

  function handle:stop()
    if self._transport then
      self._transport:close()
      self._transport = nil
    end
  end

  function handle:on(event, callback)
    self._emitter:on(event, callback)
    return self
  end

  -- Build query config from agent fields
  local nexus_config = require("nexus-agent").config()
  local query_config = vim.tbl_deep_extend("force", nexus_config, {
    model = self.model,
    system_prompt = self.system_prompt,
    permission_mode = self.permission_mode,
    max_turns = self.max_turns,
    allowed_tools = self.allowed_tools,
  })

  -- Support session resumption (set by Agent:resume())
  if self._resume_session_id then
    query_config.session_id = self._resume_session_id
  end

  -- Add MCP config if we have servers
  if #self.mcp_servers > 0 then
    query_config.mcp_servers = vim.json.decode(self:to_mcp_config())
  end

  local transport
  transport = Transport:new({
    on_message = function(raw)
      local msg = message_parser.parse(raw)
      if not msg then return end

      -- Handle control requests (tool permissions) — auto-allow
      if msg.type == "control_request" then
        local subtype = message_parser.get_control_subtype(msg)
        if subtype == "can_use_tool" then
          transport:write({
            type = "control_response",
            response = {
              subtype = "allow",
              request_id = msg.request_id,
            },
          })
        end
        return
      end

      emitter:emit("message", msg)
      if opts.on_message then vim.schedule(function() opts.on_message(msg) end) end

      -- Stream events: content deltas, block boundaries
      if msg.type == "stream_event" then
        -- Content block start (text, thinking, tool_use)
        local block_start = message_parser.extract_stream_block_start(msg)
        if block_start then
          emitter:emit("block_start", block_start)
          if opts.on_block_start then vim.schedule(function() opts.on_block_start(block_start) end) end
          -- Also emit tool_use start for backward compat
          if block_start.type == "tool_use" then
            emitter:emit("tool_use", block_start)
            if opts.on_tool_call then vim.schedule(function() opts.on_tool_call(block_start.name, {}) end) end
          end
        end

        -- Content block stop
        local block_stop_idx = message_parser.extract_stream_block_stop(msg)
        if block_stop_idx then
          emitter:emit("block_stop", block_stop_idx)
          if opts.on_block_stop then vim.schedule(function() opts.on_block_stop(block_stop_idx) end) end
        end

        -- Text delta
        local text = message_parser.extract_stream_text(msg)
        if text then
          emitter:emit("text", text)
          if opts.on_text then vim.schedule(function() opts.on_text(text) end) end
        end

        -- Thinking delta (native extended thinking)
        local thinking = message_parser.extract_stream_thinking(msg)
        if thinking then
          emitter:emit("thinking", thinking)
          if opts.on_thinking then vim.schedule(function() opts.on_thinking(thinking) end) end
        end

        return
      end

      if msg.type == "assistant" then
        local text = message_parser.extract_text(msg)
        if text ~= "" then
          emitter:emit("text", text)
          if opts.on_text then vim.schedule(function() opts.on_text(text) end) end
        end
        local tool_uses = message_parser.extract_tool_uses(msg)
        for _, tu in ipairs(tool_uses) do
          emitter:emit("tool_use", tu)
          if opts.on_tool_use then vim.schedule(function() opts.on_tool_use(tu) end) end
          if opts.on_tool_call then vim.schedule(function() opts.on_tool_call(tu.name, tu.input) end) end
        end
      elseif msg.type == "result" then
        emitter:emit("result", msg)
        emitter:emit("complete", msg)
        if opts.on_result then vim.schedule(function() opts.on_result(msg) end) end
        if opts.on_complete then vim.schedule(function() opts.on_complete(msg) end) end
      end
    end,
    on_exit = function(code)
      handle._transport = nil
      if code ~= 0 then
        local err = "Process exited with code " .. code
        emitter:emit("error", err)
        if opts.on_error then vim.schedule(function() opts.on_error(err) end) end
      end
    end,
    on_stderr = function(data)
      emitter:emit("stderr", data)
    end,
  })

  handle._transport = transport
  transport:connect(prompt, query_config)
  return handle
end

--- Resume a previous session.
--- Delegates to :run() with session_id injected so all callbacks are fully wired.
---@param session_id string The session ID to resume
---@param prompt string The follow-up prompt
---@param opts? table Same callback options as :run()
---@return table session_handle
function Agent:resume(session_id, prompt, opts)
  -- Stash session_id on the agent so :run() picks it up
  self._resume_session_id = session_id
  local handle = self:run(prompt, opts)
  self._resume_session_id = nil
  return handle
end

--- Convert agent config to CLI arguments array.
---@return string[]
function Agent:to_cli_args()
  local args = {}

  if self.model then
    table.insert(args, "--model")
    table.insert(args, self.model)
  end

  if self.system_prompt then
    table.insert(args, "--system-prompt")
    table.insert(args, self.system_prompt)
  end

  if self.permission_mode then
    table.insert(args, "--permission-mode")
    table.insert(args, self.permission_mode)
  end

  if self.max_turns then
    table.insert(args, "--max-turns")
    table.insert(args, tostring(self.max_turns))
  end

  for _, tool_name in ipairs(self.allowed_tools) do
    table.insert(args, "--allowedTools")
    table.insert(args, tool_name)
  end

  if #self.mcp_servers > 0 then
    table.insert(args, "--mcp-config")
    table.insert(args, self:to_mcp_config())
  end

  return args
end

--- Build MCP config JSON from registered MCP servers.
--- Returns a JSON string matching Claude CLI --mcp-config format.
---@return string
function Agent:to_mcp_config()
  local servers = {}
  for _, srv in ipairs(self.mcp_servers) do
    servers[srv.name] = {
      command = srv.command,
      args = srv.args,
      env = srv.env,
      cwd = srv.cwd,
    }
  end
  return vim.fn.json_encode({ mcpServers = servers })
end

--- Builder for composing agent configurations.
---@class nexus.AgentBuilder
---@field private _name string?
---@field private _description string?
---@field private _model string?
---@field private _system_prompt string?
---@field private _instructions string[]
---@field private _tools nexus.ToolDefinition[]
---@field private _mcp_servers { name: string, command: string, args: string[], env: table<string, string>, cwd: string? }[]
---@field private _permission_mode nexus.PermissionMode?
---@field private _max_turns integer?
---@field private _hooks table<nexus.HookEvent, fun(...)[]>
---@field private _cwd string?
---@field private _allowed_tools string[]
---@field private _blocks nexus.BlockType[]
local AgentBuilder = {}
AgentBuilder.__index = AgentBuilder

--- Create a new AgentBuilder instance.
---@return nexus.AgentBuilder
function AgentBuilder:new()
  return setmetatable({
    _name = nil,
    _description = nil,
    _model = nil,
    _system_prompt = nil,
    _instructions = {},
    _tools = {},
    _mcp_servers = {},
    _permission_mode = nil,
    _max_turns = nil,
    _hooks = {},
    _cwd = nil,
    _allowed_tools = {},
    _blocks = {},
  }, self)
end

--- Set the agent name.
---@param n string
---@return nexus.AgentBuilder
function AgentBuilder:name(n)
  self._name = n
  return self
end

--- Set the agent description.
---@param d string
---@return nexus.AgentBuilder
function AgentBuilder:description(d)
  self._description = d
  return self
end

--- Set the model. Accepts short names ("sonnet", "opus", "haiku") or full model IDs.
---@param m string
---@return nexus.AgentBuilder
function AgentBuilder:model(m)
  local aliases = {
    sonnet = types.MODELS.SONNET,
    opus = types.MODELS.OPUS,
    haiku = types.MODELS.HAIKU,
  }
  self._model = aliases[m] or m
  return self
end

--- Set the system prompt (raw string or InstructionBuilder:build() result).
---@param p string
---@return nexus.AgentBuilder
function AgentBuilder:system_prompt(p)
  self._system_prompt = p
  return self
end

--- Append an instruction string. Instructions are joined with the system prompt at build time.
---@param i string
---@return nexus.AgentBuilder
function AgentBuilder:instruction(i)
  table.insert(self._instructions, i)
  return self
end

--- Add a tool. Accepts a built-in tool name (string) or a ToolBuilder:build() result (table).
---@param t string|nexus.ToolDefinition
---@return nexus.AgentBuilder
function AgentBuilder:tool(t)
  if type(t) == "string" then
    table.insert(self._allowed_tools, t)
  else
    table.insert(self._tools, t)
  end
  return self
end

--- Add an MCP server (MCPBuilder:build() result).
---@param m { name: string, command: string, args: string[], env: table<string, string>, cwd: string? }
---@return nexus.AgentBuilder
function AgentBuilder:mcp_server(m)
  table.insert(self._mcp_servers, m)
  return self
end

--- Set the permission mode.
---@param m nexus.PermissionMode
---@return nexus.AgentBuilder
function AgentBuilder:permission_mode(m)
  self._permission_mode = m
  return self
end

--- Set the maximum number of conversation turns.
---@param n integer
---@return nexus.AgentBuilder
function AgentBuilder:max_turns(n)
  self._max_turns = n
  return self
end

--- Register a hook callback for an event.
---@param event nexus.HookEvent
---@param callback fun(...)
---@return nexus.AgentBuilder
function AgentBuilder:hook(event, callback)
  self._hooks[event] = self._hooks[event] or {}
  table.insert(self._hooks[event], callback)
  return self
end

--- Set the working directory.
---@param c string
---@return nexus.AgentBuilder
function AgentBuilder:cwd(c)
  self._cwd = c
  return self
end

--- Register a block type for this agent. Registered into the global BlockRegistry at build time.
--- Each block type defines how a particular XML tag (or native content type) is displayed.
---@param def nexus.BlockType
---@return nexus.AgentBuilder
function AgentBuilder:block(def)
  table.insert(self._blocks, def)
  return self
end

--- Build and validate the agent configuration. Returns an Agent instance.
---@return nexus.Agent
function AgentBuilder:build()
  assert(self._name, "AgentBuilder: 'name' is required")

  -- Compose system_prompt from _system_prompt + _instructions
  local prompt_parts = {}
  if self._system_prompt then
    table.insert(prompt_parts, self._system_prompt)
  end
  for _, inst in ipairs(self._instructions) do
    table.insert(prompt_parts, inst)
  end

  local system_prompt = nil
  if #prompt_parts > 0 then
    system_prompt = table.concat(prompt_parts, "\n\n")
  end

  -- Register custom block types into the global registry
  if #self._blocks > 0 then
    local registry = require("nexus-agent.core.block_registry").get_instance()
    for _, block_def in ipairs(self._blocks) do
      registry:register(block_def)
    end
  end

  local agent = setmetatable({
    name = self._name,
    description = self._description,
    model = self._model,
    system_prompt = system_prompt,
    tools = self._tools,
    mcp_servers = self._mcp_servers,
    permission_mode = self._permission_mode,
    max_turns = self._max_turns,
    hooks = self._hooks,
    cwd = self._cwd,
    allowed_tools = self._allowed_tools,
  }, Agent)

  return agent
end

return AgentBuilder
