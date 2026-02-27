--- Streaming XML tag parser for nexus-chat
--- State-machine based incremental parser that handles nested tags.
--- Emits events as tags open/close and text arrives, even mid-chunk.
--- Consults the BlockRegistry to know which tags to parse.

local M = {}

--- Get the block registry (lazy, avoids circular deps).
---@return nexus.BlockRegistry
local function get_registry()
  return require("nexus-agent.core.block_registry").get_instance()
end

--- Check if a tag name is registered in the block registry.
---@param name string
---@return boolean
local function is_known_tag(name)
  return get_registry():is_registered(name)
end

---@alias nexus_chat.ParserEvent
---| { type: "tag_open", tag: string, attrs: table }
---| { type: "tag_close", tag: string }
---| { type: "text", text: string, tag: string? }

--- Parser states
local S = {
  TEXT = 1,         -- Normal text outside or inside a tag
  TAG_START = 2,    -- Saw '<', deciding if tag or text
  TAG_NAME = 3,     -- Reading tag name
  TAG_ATTRS = 4,    -- Reading attributes after tag name
  TAG_CLOSE = 5,    -- Saw '</', reading close tag name
  ATTR_KEY = 6,     -- Reading attribute key
  ATTR_EQ = 7,      -- Expecting '='
  ATTR_VAL = 8,     -- Reading attribute value (inside quotes)
}

---@class nexus_chat.StreamParser
---@field _state number Current parser state
---@field _tag_stack { tag: string, attrs: table }[] Stack of open tags
---@field _buf string Accumulator for partial tokens
---@field _attr_key string Current attribute key being parsed
---@field _attr_quote string Current quote char (' or ")
---@field _attr_val string Current attribute value being parsed
---@field _attrs table Current tag's attributes
---@field _is_close boolean Whether current tag is a close tag
---@field _events nexus_chat.ParserEvent[] Events emitted during current feed()
local StreamParser = {}
StreamParser.__index = StreamParser

--- Create a new streaming parser instance.
---@return nexus_chat.StreamParser
function StreamParser:new()
  return setmetatable({
    _state = S.TEXT,
    _tag_stack = {},
    _buf = "",
    _attr_key = "",
    _attr_quote = "",
    _attr_val = "",
    _attrs = {},
    _is_close = false,
    _events = {},
  }, self)
end

--- Get the currently open tag name (top of stack), or nil if at root.
---@return string?
function StreamParser:current_tag()
  local top = self._tag_stack[#self._tag_stack]
  return top and top.tag or nil
end

--- Get the full tag stack (for nested tag info).
---@return { tag: string, attrs: table }[]
function StreamParser:stack()
  return self._tag_stack
end

--- Check if we're inside any known tag.
---@return boolean
function StreamParser:in_tag()
  return #self._tag_stack > 0
end

--- Get depth of nesting.
---@return integer
function StreamParser:depth()
  return #self._tag_stack
end

--- Emit an event.
---@param event nexus_chat.ParserEvent
---@private
function StreamParser:_emit(event)
  self._events[#self._events + 1] = event
end

--- Flush accumulated text buffer as a text event.
---@private
function StreamParser:_flush_text()
  if self._buf ~= "" then
    self:_emit({
      type = "text",
      text = self._buf,
      tag = self:current_tag(),
    })
    self._buf = ""
  end
end

--- Feed a chunk of text into the parser. Returns events generated.
--- Call this each time a stream delta arrives.
---@param chunk string
---@return nexus_chat.ParserEvent[]
function StreamParser:feed(chunk)
  self._events = {}
  local i = 1
  local len = #chunk

  while i <= len do
    local ch = chunk:sub(i, i)

    if self._state == S.TEXT then
      if ch == "<" then
        self:_flush_text()
        self._state = S.TAG_START
        self._is_close = false
        self._attrs = {}
      else
        self._buf = self._buf .. ch
      end

    elseif self._state == S.TAG_START then
      if ch == "/" then
        self._is_close = true
        self._state = S.TAG_CLOSE
        self._buf = ""
      elseif ch:match("%a") then
        self._state = S.TAG_NAME
        self._buf = ch
      else
        -- Not a valid tag, emit '<' as text
        self:_emit({
          type = "text",
          text = "<" .. ch,
          tag = self:current_tag(),
        })
        self._state = S.TEXT
        self._buf = ""
      end

    elseif self._state == S.TAG_NAME then
      if ch:match("[%w_%-]") then
        self._buf = self._buf .. ch
      elseif ch == ">" then
        local tag_name = self._buf
        self._buf = ""
        if is_known_tag(tag_name) then
          self._tag_stack[#self._tag_stack + 1] = { tag = tag_name, attrs = self._attrs }
          self:_emit({ type = "tag_open", tag = tag_name, attrs = self._attrs })
        else
          self:_emit({
            type = "text",
            text = "<" .. tag_name .. ">",
            tag = self:current_tag(),
          })
        end
        self._attrs = {}
        self._state = S.TEXT
      elseif ch == " " or ch == "\t" then
        self._state = S.TAG_ATTRS
      elseif ch == "/" then
        local tag_name = self._buf
        self._buf = ""
        if i + 1 <= len and chunk:sub(i + 1, i + 1) == ">" then
          i = i + 1
          self:_emit({
            type = "text",
            text = "<" .. tag_name .. "/>",
            tag = self:current_tag(),
          })
        end
        self._state = S.TEXT
      else
        local text = "<" .. self._buf .. ch
        self._buf = ""
        self:_emit({ type = "text", text = text, tag = self:current_tag() })
        self._state = S.TEXT
      end

    elseif self._state == S.TAG_ATTRS then
      if ch == ">" then
        local tag_name = self._buf
        self._buf = ""
        if is_known_tag(tag_name) then
          self._tag_stack[#self._tag_stack + 1] = { tag = tag_name, attrs = self._attrs }
          self:_emit({ type = "tag_open", tag = tag_name, attrs = self._attrs })
        else
          local attr_str = ""
          for k, v in pairs(self._attrs) do
            if v == true then
              attr_str = attr_str .. " " .. k
            else
              attr_str = attr_str .. " " .. k .. '="' .. v .. '"'
            end
          end
          self:_emit({
            type = "text",
            text = "<" .. tag_name .. attr_str .. ">",
            tag = self:current_tag(),
          })
        end
        self._attrs = {}
        self._state = S.TEXT
      elseif ch:match("%a") then
        self._attr_key = ch
        self._state = S.ATTR_KEY
      elseif ch == " " or ch == "\t" then
        -- skip whitespace
      else
        local text = "<" .. self._buf
        self._buf = ""
        self:_emit({ type = "text", text = text .. ch, tag = self:current_tag() })
        self._attrs = {}
        self._state = S.TEXT
      end

    elseif self._state == S.ATTR_KEY then
      if ch:match("[%w_%-]") then
        self._attr_key = self._attr_key .. ch
      elseif ch == "=" then
        self._state = S.ATTR_EQ
      elseif ch == " " then
        self._attrs[self._attr_key] = true
        self._attr_key = ""
        self._state = S.TAG_ATTRS
      elseif ch == ">" then
        self._attrs[self._attr_key] = true
        self._attr_key = ""
        local tag_name = self._buf
        self._buf = ""
        if is_known_tag(tag_name) then
          self._tag_stack[#self._tag_stack + 1] = { tag = tag_name, attrs = self._attrs }
          self:_emit({ type = "tag_open", tag = tag_name, attrs = self._attrs })
        else
          self:_emit({
            type = "text",
            text = "<" .. tag_name .. ">",
            tag = self:current_tag(),
          })
        end
        self._attrs = {}
        self._state = S.TEXT
      end

    elseif self._state == S.ATTR_EQ then
      if ch == '"' or ch == "'" then
        self._attr_quote = ch
        self._attr_val = ""
        self._state = S.ATTR_VAL
      else
        self._attrs[self._attr_key] = true
        self._attr_key = ""
        self._state = S.TAG_ATTRS
        i = i - 1  -- re-process this char
      end

    elseif self._state == S.ATTR_VAL then
      if ch == self._attr_quote then
        self._attrs[self._attr_key] = self._attr_val
        self._attr_key = ""
        self._attr_val = ""
        self._state = S.TAG_ATTRS
      else
        self._attr_val = self._attr_val .. ch
      end

    elseif self._state == S.TAG_CLOSE then
      if ch:match("[%w_%-]") then
        self._buf = self._buf .. ch
      elseif ch == ">" then
        local tag_name = self._buf
        self._buf = ""
        if #self._tag_stack > 0 and self._tag_stack[#self._tag_stack].tag == tag_name then
          self._tag_stack[#self._tag_stack] = nil
          self:_emit({ type = "tag_close", tag = tag_name })
        elseif is_known_tag(tag_name) then
          for j = #self._tag_stack, 1, -1 do
            if self._tag_stack[j].tag == tag_name then
              for k = #self._tag_stack, j, -1 do
                self:_emit({ type = "tag_close", tag = self._tag_stack[k].tag })
                self._tag_stack[k] = nil
              end
              break
            end
          end
        else
          self:_emit({
            type = "text",
            text = "</" .. tag_name .. ">",
            tag = self:current_tag(),
          })
        end
        self._state = S.TEXT
      elseif ch == " " then
        -- ignore whitespace in close tag
      else
        local text = "</" .. self._buf .. ch
        self._buf = ""
        self:_emit({ type = "text", text = text, tag = self:current_tag() })
        self._state = S.TEXT
      end
    end

    i = i + 1
  end

  -- Flush remaining text (not partial tags)
  if self._state == S.TEXT then
    self:_flush_text()
  end

  return self._events
end

--- Reset the parser to initial state.
function StreamParser:reset()
  self._state = S.TEXT
  self._tag_stack = {}
  self._buf = ""
  self._attr_key = ""
  self._attr_quote = ""
  self._attr_val = ""
  self._attrs = {}
  self._is_close = false
  self._events = {}
end

-- Exports
M.StreamParser = StreamParser

--- Create a new streaming parser.
---@return nexus_chat.StreamParser
function M.new()
  return StreamParser:new()
end

return M
