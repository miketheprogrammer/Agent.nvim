--- nexus-agent.nvim — Plugin entry point
--- AI Agent SDK for Neovim using Claude Code CLI as backend.

local Transport = require("nexus-agent.core.transport")
local message_parser = require("nexus-agent.core.message_parser")
local EventEmitter = require("nexus-agent.events")
local types = require("nexus-agent.types")

local M = {}

--- Default configuration
---@type nexus.Config
local config = {
  cli_path = vim.fn.expand("~") .. "/.local/bin/claude",
  model = "sonnet",
  cache_dir = vim.fn.expand("~") .. "/.cache/nvim/nexus-agent",
  permission_mode = "acceptEdits",
  system_prompt = nil,
  allowed_tools = nil,
  mcp_servers = nil,
  max_turns = nil,
  debug = false,
}

--- Active state
local state = {
  transport = nil, ---@type nexus.Transport|nil
  session_manager = nil, ---@type nexus.SessionManager|nil
  tool_registry = nil, ---@type nexus.ToolRegistry|nil
  chat_buffer = nil, ---@type nexus.ChatBuffer|nil
  events = EventEmitter:new(),
}

--- Get the current configuration.
---@return nexus.Config
function M.config()
  return config
end

--- Setup the plugin.
---@param opts? table User configuration overrides
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  -- Ensure cache directory exists
  vim.fn.mkdir(config.cache_dir, "p")
  vim.fn.mkdir(config.cache_dir .. "/sessions", "p")
  vim.fn.mkdir(config.cache_dir .. "/agents", "p")

  -- Initialize session manager
  state.session_manager = require("nexus-agent.session.manager"):new({
    cache_dir = config.cache_dir,
  })

  -- Initialize tool registry
  state.tool_registry = require("nexus-agent.core.tool_registry"):new()

  if config.debug then
    vim.notify("nexus-agent.nvim loaded", vim.log.levels.INFO)
  end
end

--- Run a query: spawn transport, stream response into a buffer.
---@param prompt string
---@param opts? table Per-query overrides
function M.ask(prompt, opts)
  if not prompt or prompt == "" then
    vim.ui.input({ prompt = "Nexus> " }, function(input)
      if input and input ~= "" then
        M.ask(input, opts)
      end
    end)
    return
  end

  opts = opts or {}
  local query_config = vim.tbl_deep_extend("force", config, opts)

  -- Create or reuse chat buffer
  local ChatBuffer = require("nexus-agent.ui.chat_buffer")
  if not state.chat_buffer or not vim.api.nvim_buf_is_valid(state.chat_buffer:bufnr()) then
    state.chat_buffer = ChatBuffer:new("nexus://agent")
  end

  local buf = state.chat_buffer
  if not buf:winnr() or not vim.api.nvim_win_is_valid(buf:winnr()) then
    buf:open("right")
  end

  buf:user_header(prompt)
  buf:assistant_header()

  -- Update status
  local status = require("nexus-agent.ui.status")
  status.get_instance():set_state("thinking", { agent_name = "nexus" })

  -- Create session
  local session = state.session_manager:create({
    name = opts.agent_name or "default",
    model = query_config.model,
  })
  session.prompt = prompt

  -- Spawn transport
  local transport = Transport:new({
    on_message = function(raw)
      local msg = message_parser.parse(raw)
      if not msg then return end

      -- Handle control requests (tool permissions) — respond immediately
      if msg.type == "control_request" then
        local subtype = message_parser.get_control_subtype(msg)
        if subtype == "can_use_tool" then
          -- Auto-allow tool use (permission_mode handles this at CLI level)
          state.transport:write({
            type = "control_response",
            response = {
              subtype = "allow",
              request_id = msg.request_id,
            },
          })
        end
        return -- Don't accumulate control messages
      end

      -- Accumulate in session
      table.insert(session.messages, msg)
      state.events:emit("message", msg)

      -- Stream events: content deltas arrive here
      if msg.type == "stream_event" then
        local text = message_parser.extract_stream_text(msg)
        if text then
          buf:append(text)
          status.get_instance():set_state("streaming")
        end
        -- Check for tool_use start
        local tool_start = message_parser.extract_stream_tool_use_start(msg)
        if tool_start then
          buf:append_tool_use(tool_start.name, {})
          status.get_instance():set_state("tool_use")
          state.events:emit("tool_call", tool_start)
        end
        return
      end

      if msg.type == "assistant" then
        local text = message_parser.extract_text(msg)
        if text ~= "" then
          buf:append(text)
          status.get_instance():set_state("streaming")
        end
        -- Handle tool uses
        local tool_uses = message_parser.extract_tool_uses(msg)
        for _, tu in ipairs(tool_uses) do
          buf:append_tool_use(tu.name, tu.input)
          status.get_instance():set_state("tool_use")
          state.events:emit("tool_call", tu)
        end
      elseif msg.type == "result" then
        -- Capture session_id for multi-turn
        if msg.session_id then
          session.session_id = msg.session_id
        end
        session.result = msg.result
        buf:_append_lines({ "", "---" })
        if msg.cost_usd then
          buf:_append_lines({
            string.format("*Cost: $%.4f | Turns: %d | Duration: %dms*",
              msg.cost_usd or 0, msg.num_turns or 0, msg.duration_ms or 0),
          })
        end
        -- Save session
        state.session_manager:save_active(msg)
        status.get_instance():set_state("complete", {
          cost = msg.cost_usd or 0,
        })
        state.events:emit("complete", msg)
      end
    end,
    on_exit = function(code)
      state.transport = nil
      if code ~= 0 then
        buf:_append_lines({ "", "**Process exited with code " .. code .. "**" })
        status.get_instance():set_state("error")
      end
    end,
    on_stderr = function(data)
      if config.debug then
        vim.notify("[nexus-agent stderr] " .. data, vim.log.levels.DEBUG)
      end
    end,
    on_state_change = function(s)
      if config.debug then
        vim.notify("[nexus-agent] state: " .. s, vim.log.levels.DEBUG)
      end
    end,
  })

  state.transport = transport
  transport:connect(prompt, query_config)
end

--- Run a named agent with a prompt.
---@param agent_name string
---@param prompt string
function M.run_agent(agent_name, prompt)
  -- Load agent definition from disk
  local agents_dir = config.cache_dir .. "/agents"
  local path = agents_dir .. "/" .. agent_name .. ".json"
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Agent not found: " .. agent_name, vim.log.levels.ERROR)
    return
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, def = pcall(vim.json.decode, content)
  if not ok then
    vim.notify("Failed to parse agent: " .. agent_name, vim.log.levels.ERROR)
    return
  end

  M.ask(prompt, {
    agent_name = agent_name,
    model = def.model,
    system_prompt = def.system_prompt,
    permission_mode = def.permission_mode,
    max_turns = def.max_turns,
    allowed_tools = def.tools,
  })
end

--- Resume a previous session.
---@param session_id? string If nil, opens Telescope picker
---@param prompt? string Follow-up prompt
function M.resume(session_id, prompt)
  if not session_id then
    require("nexus-agent.telescope.sessions").sessions()
    return
  end

  if not prompt then
    vim.ui.input({ prompt = "Follow-up: " }, function(input)
      if input and input ~= "" then
        M.resume(session_id, input)
      end
    end)
    return
  end

  -- Resume via transport with --resume flag
  M.ask(prompt, { session_id = session_id })
end

--- Stop the active transport.
function M.stop()
  if state.transport then
    state.transport:close()
    state.transport = nil
    local status = require("nexus-agent.ui.status")
    status.get_instance():set_state("idle")
    vim.notify("Agent stopped", vim.log.levels.INFO)
  end
end

--- Open agent editor for a new agent.
function M.new_agent()
  require("nexus-agent.ui.agent_editor"):new():open()
end

--- Edit an existing agent.
---@param agent_name string
function M.edit_agent(agent_name)
  local agents_dir = config.cache_dir .. "/agents"
  local path = agents_dir .. "/" .. agent_name .. ".json"
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("Agent not found: " .. agent_name, vim.log.levels.ERROR)
    return
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, def = pcall(vim.json.decode, content)
  if ok then
    require("nexus-agent.ui.agent_editor"):new():open(def)
  end
end

--- Telescope pickers
function M.sessions() require("nexus-agent.telescope.sessions").sessions() end
function M.agents() require("nexus-agent.telescope.agents").agents() end
function M.tools() require("nexus-agent.telescope.tools").tools() end
function M.activity() require("nexus-agent.telescope.messages").messages() end
function M.mcp_status() require("nexus-agent.telescope.mcp_servers").mcp_servers() end
function M.changes() require("nexus-agent.telescope.git_changes").git_changes() end

--- Public API re-exports (builder pattern)
function M.agent() return require("nexus-agent.builder.agent"):new() end
function M.tool() return require("nexus-agent.builder.tool"):new() end
function M.mcp() return require("nexus-agent.builder.mcp"):new() end
function M.instructions() return require("nexus-agent.builder.instruction"):new() end

--- Register a custom tool.
---@param def nexus.ToolDefinition
function M.register_tool(def)
  if state.tool_registry then
    state.tool_registry:register(def)
  end
end

--- Subscribe to events.
---@param event string
---@param callback function
function M.on(event, callback)
  state.events:on(event, callback)
end

--- Register user commands and keymaps.
---@private
function M._register_commands()
  vim.api.nvim_create_user_command("NexusRun", function(cmd_opts)
    local args = cmd_opts.args
    local parts = vim.split(args, " ", { trimempty = true })
    if #parts < 2 then
      vim.notify("Usage: :NexusRun {agent} {prompt}", vim.log.levels.WARN)
      return
    end
    local agent_name = table.remove(parts, 1)
    local prompt = table.concat(parts, " ")
    M.run_agent(agent_name, prompt)
  end, { nargs = "+", desc = "Run a nexus agent with a prompt" })

  vim.api.nvim_create_user_command("NexusAsk", function(cmd_opts)
    M.ask(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?", desc = "Send a prompt to the default agent" })

  vim.api.nvim_create_user_command("NexusChat", function()
    require("nexus-chat").toggle()
  end, { desc = "Toggle nexus chat" })

  vim.api.nvim_create_user_command("NexusChatHistory", function()
    require("nexus-chat").history()
  end, { desc = "Browse chat message history" })

  vim.api.nvim_create_user_command("NexusChatNew", function()
    require("nexus-chat").new_session()
  end, { desc = "Start a new chat session" })

  vim.api.nvim_create_user_command("NexusChatSessions", function()
    require("nexus-chat").sessions()
  end, { desc = "Browse Claude CLI chat sessions" })

  vim.api.nvim_create_user_command("NexusChatModel", function()
    require("nexus-chat").pick_model()
  end, { desc = "Pick chat model" })

  vim.api.nvim_create_user_command("NexusChatAgent", function()
    require("nexus-chat").pick_agent()
  end, { desc = "Pick chat agent" })

  vim.api.nvim_create_user_command("NexusNew", function()
    M.new_agent()
  end, { desc = "Create a new agent" })

  vim.api.nvim_create_user_command("NexusEdit", function(cmd_opts)
    M.edit_agent(cmd_opts.args)
  end, { nargs = 1, desc = "Edit an agent definition" })

  vim.api.nvim_create_user_command("NexusSessions", function()
    M.sessions()
  end, { desc = "Browse sessions" })

  vim.api.nvim_create_user_command("NexusAgents", function()
    M.agents()
  end, { desc = "Browse agents" })

  vim.api.nvim_create_user_command("NexusTools", function()
    M.tools()
  end, { desc = "Browse tools" })

  vim.api.nvim_create_user_command("NexusActivity", function()
    M.activity()
  end, { desc = "Live activity feed" })

  vim.api.nvim_create_user_command("NexusMCP", function()
    M.mcp_status()
  end, { desc = "MCP server status" })

  vim.api.nvim_create_user_command("NexusChanges", function()
    M.changes()
  end, { desc = "Git changes from agent" })

  vim.api.nvim_create_user_command("NexusStop", function()
    M.stop()
  end, { desc = "Stop active agent" })

  vim.api.nvim_create_user_command("NexusResume", function(cmd_opts)
    if cmd_opts.args ~= "" then
      M.resume(cmd_opts.args)
    else
      M.resume()
    end
  end, { nargs = "?", desc = "Resume a session" })

  vim.api.nvim_create_user_command("NexusInline", function(cmd_opts)
    local opts = {}
    if cmd_opts.range == 2 then
      opts.line1 = cmd_opts.line1
      opts.line2 = cmd_opts.line2
    end
    require("nexus-inline").open(opts)
  end, { range = true, desc = "Inline prompt for code editing" })
end

-- Register commands at module load time so they're always available
M._register_commands()

return M
