--- Shared type definitions for nexus-agent.nvim
--- LuaCATS annotations for all types used across the plugin.

---@alias nexus.MessageType "user"|"assistant"|"system"|"result"

---@alias nexus.ContentType "text"|"thinking"|"tool_use"|"tool_result"

---@alias nexus.PermissionMode "default"|"plan"|"auto-accept"|"bypass"

--- Content block types ---

---@class nexus.TextBlock
---@field type "text"
---@field text string

---@class nexus.ThinkingBlock
---@field type "thinking"
---@field thinking string

---@class nexus.ToolUseBlock
---@field type "tool_use"
---@field id string
---@field name string
---@field input table

---@class nexus.ToolResultBlock
---@field type "tool_result"
---@field tool_use_id string
---@field content string|table
---@field is_error? boolean

---@alias nexus.ContentBlock nexus.TextBlock|nexus.ThinkingBlock|nexus.ToolUseBlock|nexus.ToolResultBlock

--- Message types ---

---@class nexus.UserMessage
---@field type "user"
---@field content string|nexus.ContentBlock[]

---@class nexus.AssistantMessage
---@field type "assistant"
---@field content nexus.ContentBlock[]
---@field model? string
---@field stop_reason? string

---@class nexus.SystemMessage
---@field type "system"
---@field content string
---@field subtype? string

---@class nexus.ResultMessage
---@field type "result"
---@field subtype? string
---@field result? string
---@field is_error? boolean
---@field duration_ms? number
---@field duration_api_ms? number
---@field num_turns? number
---@field session_id? string
---@field cost_usd? number
---@field usage? { input_tokens: integer, output_tokens: integer, cache_read_tokens: integer, cache_write_tokens: integer }

---@class nexus.StreamEvent
---@field type string
---@field subtype? string
---@field data? table

---@alias nexus.Message nexus.UserMessage|nexus.AssistantMessage|nexus.SystemMessage|nexus.ResultMessage|nexus.StreamEvent

--- Configuration ---

---@class nexus.Config
---@field cli_path string Path to the Claude CLI executable
---@field model? string Model to use (e.g. "claude-sonnet-4-20250514")
---@field cache_dir? string Directory for session cache
---@field permission_mode? nexus.PermissionMode Permission mode for tool use
---@field system_prompt? string System prompt override
---@field allowed_tools? string[] List of allowed tool names
---@field mcp_servers? table<string, nexus.McpServerConfig> MCP server configurations
---@field max_turns? integer Maximum conversation turns
---@field cwd? string Working directory for the Claude subprocess
---@field debug? boolean Enable debug logging

---@class nexus.McpServerConfig
---@field command string
---@field args? string[]
---@field env? table<string, string>

--- Transport callbacks ---

---@class nexus.TransportCallbacks
---@field on_message fun(msg: table) Called for each parsed JSON message from stdout
---@field on_exit fun(code: integer) Called when the subprocess exits
---@field on_stderr? fun(data: string) Called for stderr output
---@field on_state_change? fun(state: string) Called when transport state changes

--- Query callbacks ---

---@class nexus.QueryCallbacks
---@field on_message? fun(msg: nexus.Message) Called for each parsed message
---@field on_text? fun(text: string) Called for text content
---@field on_tool_use? fun(block: nexus.ToolUseBlock) Called for tool use blocks
---@field on_result? fun(msg: nexus.ResultMessage) Called when conversation ends
---@field on_error? fun(err: string) Called on error

--- Session record ---

---@class nexus.Session
---@field id string Session identifier
---@field model? string Model used
---@field created_at integer Timestamp of creation
---@field updated_at integer Timestamp of last update
---@field messages nexus.Message[] Conversation messages
---@field cost_usd? number Total cost in USD
---@field usage? { input_tokens: integer, output_tokens: integer }

--- Tool definition ---

---@class nexus.ToolDefinition
---@field name string Tool name
---@field description string Tool description
---@field input_schema table JSON schema for tool input
---@field handler fun(input: table): string|table Tool implementation

--- Hook event ---

---@alias nexus.HookEvent "pre_query"|"post_query"|"on_message"|"on_tool_use"|"on_error"|"on_result"

--- Constants ---

local M = {}

---@enum nexus.MESSAGE_TYPES
M.MESSAGE_TYPES = {
  USER = "user",
  ASSISTANT = "assistant",
  SYSTEM = "system",
  RESULT = "result",
}

---@enum nexus.CONTENT_TYPES
M.CONTENT_TYPES = {
  TEXT = "text",
  THINKING = "thinking",
  TOOL_USE = "tool_use",
  TOOL_RESULT = "tool_result",
}

---@enum nexus.PERMISSION_MODES
M.PERMISSION_MODES = {
  DEFAULT = "default",
  PLAN = "plan",
  AUTO_ACCEPT = "auto-accept",
  BYPASS = "bypass",
}

---@enum nexus.MODELS
M.MODELS = {
  OPUS = "claude-opus-4-6",
  SONNET = "claude-sonnet-4-6",
  HAIKU = "claude-haiku-4-5-20251001",
}

return M
