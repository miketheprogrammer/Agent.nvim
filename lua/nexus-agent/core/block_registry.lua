--- Block Type Registry for nexus-agent
--- Agents register block types (XML tags or native content types) with
--- display config. The streaming parser and renderer consult this registry
--- to know which tags to handle and how to render them.
---
--- This is a singleton — all agents share the same registry within a session.

---@class nexus.BlockType
---@field tag string                     Tag name (e.g. "thinking", "analysis")
---@field color string                   Primary neon color hex (e.g. "#af5fff")
---@field bg string                      Background tint hex (e.g. "#1a1a2a")
---@field icon string                    Nerd Font icon + trailing space (e.g. "󰠗 ")
---@field active_label string            Label while block is streaming (e.g. "Agent is thinking")
---@field done_label string              Label when block is complete (e.g. "Agent Thought")
---@field collapsed_default boolean?     Whether to collapse after completion (default false)
---@field native_type string?            If set, maps to a native Claude content block type (e.g. "thinking")
---@field render_content fun(bufnr: integer, text: string, attrs: table)?  Optional custom content renderer

---@class nexus.BlockRegistry
---@field private _blocks table<string, nexus.BlockType>  tag -> block type
---@field private _native_map table<string, string>       native type -> tag
local BlockRegistry = {}
BlockRegistry.__index = BlockRegistry

--- Singleton instance
local _instance = nil

--- Get the singleton registry instance.
---@return nexus.BlockRegistry
function BlockRegistry.get_instance()
  if not _instance then
    _instance = setmetatable({
      _blocks = {},
      _native_map = {},
    }, BlockRegistry)
    -- Register default block types
    _instance:_register_defaults()
  end
  return _instance
end

--- Register a block type.
---@param def nexus.BlockType
---@return nexus.BlockRegistry self
function BlockRegistry:register(def)
  assert(def.tag, "BlockType requires a 'tag' field")
  assert(def.color, "BlockType requires a 'color' field")
  assert(def.icon, "BlockType requires an 'icon' field")
  assert(def.active_label, "BlockType requires an 'active_label' field")
  assert(def.done_label, "BlockType requires a 'done_label' field")

  -- Default bg to a darkened version of the color
  if not def.bg then
    def.bg = "#1a1a1e"
  end

  self._blocks[def.tag] = def

  -- Map native content block type to tag
  if def.native_type then
    self._native_map[def.native_type] = def.tag
  end

  -- Create highlight groups for this block type
  self:_setup_hl(def)

  return self
end

--- Unregister a block type.
---@param tag string
function BlockRegistry:unregister(tag)
  local def = self._blocks[tag]
  if def and def.native_type then
    self._native_map[def.native_type] = nil
  end
  self._blocks[tag] = nil
end

--- Get a block type definition by tag name.
---@param tag string
---@return nexus.BlockType?
function BlockRegistry:get(tag)
  return self._blocks[tag]
end

--- Check if a tag is registered.
---@param tag string
---@return boolean
function BlockRegistry:is_registered(tag)
  return self._blocks[tag] ~= nil
end

--- Get the tag name for a native content block type (e.g. "thinking" -> "thinking").
---@param native_type string
---@return string?
function BlockRegistry:tag_for_native(native_type)
  return self._native_map[native_type]
end

--- Get all registered tag names.
---@return string[]
function BlockRegistry:tags()
  local tags = {}
  for tag in pairs(self._blocks) do
    tags[#tags + 1] = tag
  end
  return tags
end

--- Get all registered block types as a table (tag -> def).
---@return table<string, nexus.BlockType>
function BlockRegistry:all()
  return self._blocks
end

--- Get the highlight group name for a tag + suffix.
---@param tag string
---@param suffix string  "Header", "HeaderBg", "Border", "Bg"
---@return string
function BlockRegistry.hl_group(tag, suffix)
  return "NexusBlock" .. tag:sub(1, 1):upper() .. tag:sub(2) .. suffix
end

--- Setup highlight groups for a block type.
---@param def nexus.BlockType
---@private
function BlockRegistry:_setup_hl(def)
  local tag = def.tag
  local hi = vim.api.nvim_set_hl

  hi(0, BlockRegistry.hl_group(tag, "Header"), {
    fg = def.color,
    bold = true,
  })
  hi(0, BlockRegistry.hl_group(tag, "HeaderBg"), {
    fg = def.color,
    bg = def.bg,
    bold = true,
  })
  hi(0, BlockRegistry.hl_group(tag, "Border"), {
    fg = def.color,
  })
  hi(0, BlockRegistry.hl_group(tag, "Bg"), {
    bg = def.bg,
  })
end

--- Re-setup all highlights (e.g., after colorscheme change).
function BlockRegistry:refresh_highlights()
  for _, def in pairs(self._blocks) do
    self:_setup_hl(def)
  end
end

--- Register the default block types.
---@private
function BlockRegistry:_register_defaults()
  self:register({
    tag = "thinking",
    color = "#af5fff",
    bg = "#1a1a2a",
    icon = "󰠗 ",
    active_label = "Agent is thinking",
    done_label = "Agent Thought",
    collapsed_default = false,
    native_type = "thinking",  -- maps to Claude's native extended thinking
  })
  self:register({
    tag = "response",
    color = "#5fffff",
    bg = "#1a2a2a",
    icon = "󰍩 ",
    active_label = "Responding",
    done_label = "Response",
    collapsed_default = false,
  })
  self:register({
    tag = "code",
    color = "#5fff87",
    bg = "#1a2a1a",
    icon = " ",
    active_label = "Writing code",
    done_label = "Code",
    collapsed_default = false,
  })
  self:register({
    tag = "shell",
    color = "#ffff5f",
    bg = "#2a2a1a",
    icon = " ",
    active_label = "Shell command",
    done_label = "Shell",
    collapsed_default = false,
  })
  self:register({
    tag = "artifact",
    color = "#ffaf5f",
    bg = "#2a1a1a",
    icon = "󰈔 ",
    active_label = "Generating artifact",
    done_label = "Artifact",
    collapsed_default = true,
  })
  self:register({
    tag = "tool",
    color = "#5fafff",
    bg = "#1a1a2a",
    icon = "󰒍 ",
    active_label = "Using tool",
    done_label = "Tool",
    collapsed_default = true,
    native_type = "tool_use",
  })
  self:register({
    tag = "result",
    color = "#999999",
    bg = "#1a1a1e",
    icon = "󰑃 ",
    active_label = "Result",
    done_label = "Result",
    collapsed_default = true,
  })
end

--- Reset to defaults (useful for testing).
function BlockRegistry:reset()
  self._blocks = {}
  self._native_map = {}
  self:_register_defaults()
end

return BlockRegistry
