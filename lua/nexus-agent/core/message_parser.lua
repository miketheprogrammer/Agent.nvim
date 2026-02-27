--- Message Parser for nexus-agent.nvim
--- Parses raw JSON tables from Claude CLI stream-json output into typed message tables.
--- Handles: assistant, user, system, result, stream_event, control_request, control_response

local types = require("nexus-agent.types")

local M = {}

--- Parse a single content block from an assistant message.
---@param block table Raw content block
---@return nexus.ContentBlock? parsed The parsed block, or nil if unknown
function M.parse_content_block(block)
  if not block or not block.type then
    return nil
  end

  if block.type == types.CONTENT_TYPES.TEXT then
    return { type = "text", text = block.text or "" }
  end

  if block.type == types.CONTENT_TYPES.THINKING then
    return { type = "thinking", thinking = block.thinking or "" }
  end

  if block.type == types.CONTENT_TYPES.TOOL_USE then
    return {
      type = "tool_use",
      id = block.id or "",
      name = block.name or "",
      input = block.input or {},
    }
  end

  if block.type == types.CONTENT_TYPES.TOOL_RESULT then
    return {
      type = "tool_result",
      tool_use_id = block.tool_use_id or "",
      content = block.content or "",
      is_error = block.is_error,
    }
  end

  return nil
end

--- Parse content blocks array from an assistant message.
---@param raw_blocks table[] Raw content block array
---@return nexus.ContentBlock[]
---@private
local function parse_content_blocks(raw_blocks)
  local blocks = {}
  for _, raw_block in ipairs(raw_blocks) do
    local parsed = M.parse_content_block(raw_block)
    if parsed then
      blocks[#blocks + 1] = parsed
    end
  end
  return blocks
end

--- Parse a raw JSON table from CLI stream-json output into a typed message.
---@param raw table Raw message from JSON
---@return table? message The parsed message, or nil for unknown types
function M.parse(raw)
  if not raw or not raw.type then
    return nil
  end

  -- Assistant message: {type:"assistant", message:{role,content,model,...}}
  if raw.type == "assistant" then
    -- Content can be in raw.message.content (stream-json) or raw.content (simple)
    local msg_data = raw.message or raw
    local content = {}
    if type(msg_data.content) == "table" then
      content = parse_content_blocks(msg_data.content)
    end
    return {
      type = "assistant",
      content = content,
      model = msg_data.model or raw.model,
      stop_reason = msg_data.stop_reason or raw.stop_reason,
      error = raw.error,
    }
  end

  -- User message
  if raw.type == "user" then
    local msg_data = raw.message or raw
    return {
      type = "user",
      content = msg_data.content or raw.content or "",
      uuid = raw.uuid,
      parent_tool_use_id = raw.parent_tool_use_id,
    }
  end

  -- System message (subtype "init" carries session_id)
  if raw.type == "system" then
    return {
      type = "system",
      content = raw.content or "",
      subtype = raw.subtype,
      session_id = raw.session_id,
    }
  end

  -- Result message
  if raw.type == "result" then
    -- Cost can be in total_cost_usd or nested cost object
    local cost = raw.total_cost_usd
    if not cost and raw.cost then
      cost = raw.cost.total or raw.cost
    end
    return {
      type = "result",
      subtype = raw.subtype,
      result = raw.result,
      is_error = raw.is_error,
      duration_ms = raw.duration_ms,
      duration_api_ms = raw.duration_api_ms,
      num_turns = raw.num_turns,
      session_id = raw.session_id,
      conversation_id = raw.conversation_id,
      cost_usd = cost,
      usage = raw.usage,
    }
  end

  -- Stream event: content deltas, tool use deltas, etc.
  if raw.type == "stream_event" or raw.type == "stream" then
    -- Event data can be nested ({event:{type,index,data}}) or flat ({event:"name",index:N,data:{}})
    local event = raw.event or {}
    local event_type, event_index, event_data
    if type(event) == "table" then
      event_type = event.type
      event_index = event.index
      event_data = event.data or event
    elseif type(event) == "string" then
      event_type = event
      event_index = raw.index
      event_data = raw.data or {}
    end

    return {
      type = "stream_event",
      event_type = event_type,
      event_index = event_index,
      event_data = event_data,
      uuid = raw.uuid,
      session_id = raw.session_id,
      parent_tool_use_id = raw.parent_tool_use_id,
      raw = raw,
    }
  end

  -- Control request: tool permissions, etc.
  if raw.type == "control_request" then
    return {
      type = "control_request",
      request_id = raw.request_id,
      request = raw.request or {},
    }
  end

  -- Control response
  if raw.type == "control_response" then
    return {
      type = "control_response",
      response = raw.response or {},
    }
  end

  -- Unknown type — pass through as-is
  return {
    type = raw.type,
    data = raw,
  }
end

--- Extract the text delta from a stream event (content_block_delta).
---@param msg table Parsed stream_event message
---@return string? text The delta text, or nil if not a text delta
function M.extract_stream_text(msg)
  if msg.type ~= "stream_event" then return nil end
  if msg.event_type ~= "content_block_delta" then return nil end

  local data = msg.event_data or {}
  -- Delta can be in data.delta.text or data.text
  if data.delta and data.delta.text then
    return data.delta.text
  end
  if data.text then
    return data.text
  end
  return nil
end

--- Extract thinking delta text from a stream event (content_block_delta with thinking_delta).
--- Native extended thinking (Opus, etc.) sends thinking content as a separate delta type.
---@param msg table Parsed stream_event message
---@return string? thinking The thinking delta text, or nil if not a thinking delta
function M.extract_stream_thinking(msg)
  if msg.type ~= "stream_event" then return nil end
  if msg.event_type ~= "content_block_delta" then return nil end

  local data = msg.event_data or {}
  -- Thinking delta: data.delta.type == "thinking_delta", text in data.delta.thinking
  if data.delta and data.delta.type == "thinking_delta" and data.delta.thinking then
    return data.delta.thinking
  end
  -- Flat format fallback
  if data.type == "thinking_delta" and data.thinking then
    return data.thinking
  end
  return nil
end

--- Extract the content block type from a content_block_start stream event.
--- Returns the block type ("text", "thinking", "tool_use") and any metadata.
---@param msg table Parsed stream_event message
---@return table? block_info { type: string, index: number?, id: string?, name: string? }
function M.extract_stream_block_start(msg)
  if msg.type ~= "stream_event" then return nil end
  if msg.event_type ~= "content_block_start" then return nil end

  local data = msg.event_data or {}
  local block = data.content_block or data
  if not block.type then return nil end
  return {
    type = block.type,
    index = msg.event_index or data.index,
    id = block.id,
    name = block.name,
  }
end

--- Check if a stream event is a content_block_stop.
---@param msg table Parsed stream_event message
---@return number? index The content block index that stopped, or nil
function M.extract_stream_block_stop(msg)
  if msg.type ~= "stream_event" then return nil end
  if msg.event_type ~= "content_block_stop" then return nil end

  local data = msg.event_data or {}
  return msg.event_index or data.index
end

--- Check if a stream event is a content_block_start with tool_use.
---@param msg table
---@return table? tool_use {id, name} if it's a tool_use start
function M.extract_stream_tool_use_start(msg)
  if msg.type ~= "stream_event" then return nil end
  if msg.event_type ~= "content_block_start" then return nil end

  local data = msg.event_data or {}
  local block = data.content_block or data
  if block.type == "tool_use" then
    return { id = block.id, name = block.name }
  end
  return nil
end

--- Extract plain text content from any message type.
---@param message table
---@return string text The extracted text
function M.extract_text(message)
  if not message then return "" end

  -- Stream event text delta
  if message.type == "stream_event" then
    return M.extract_stream_text(message) or ""
  end

  -- User message with string content
  if message.type == "user" and type(message.content) == "string" then
    return message.content
  end

  -- Result message
  if message.type == "result" then
    return message.result or ""
  end

  -- System message
  if message.type == "system" then
    return type(message.content) == "string" and message.content or ""
  end

  -- Assistant message with content blocks
  if message.type == "assistant" and type(message.content) == "table" then
    local parts = {}
    for _, block in ipairs(message.content) do
      if block.type == "text" then
        parts[#parts + 1] = block.text
      elseif block.type == "thinking" then
        parts[#parts + 1] = block.thinking
      end
    end
    return table.concat(parts, "\n")
  end

  return ""
end

--- Extract tool_use blocks from an assistant message.
---@param message table
---@return nexus.ToolUseBlock[]
function M.extract_tool_uses(message)
  local tool_uses = {}
  if not message or message.type ~= "assistant" then
    return tool_uses
  end
  if type(message.content) ~= "table" then
    return tool_uses
  end
  for _, block in ipairs(message.content) do
    if block.type == "tool_use" then
      tool_uses[#tool_uses + 1] = block
    end
  end
  return tool_uses
end

--- Check if a message is a result (conversation end).
---@param message table
---@return boolean
function M.is_final(message)
  return message ~= nil and message.type == "result"
end

--- Check if a message is a control request (needs response).
---@param message table
---@return boolean
function M.is_control_request(message)
  return message ~= nil and message.type == "control_request"
end

--- Get the subtype of a control request (e.g., "can_use_tool").
---@param message table
---@return string?
function M.get_control_subtype(message)
  if not M.is_control_request(message) then return nil end
  return message.request and message.request.subtype
end

return M
