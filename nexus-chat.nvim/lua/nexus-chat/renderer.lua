--- Rich renderer for nexus-chat
--- Renders streaming parser events into the chat buffer with neon-colored
--- collapsible blocks, animated headers, and duration tracking.
--- All block type config comes from the BlockRegistry.

local M = {}

--- Get the block registry.
---@return nexus.BlockRegistry
local function get_registry()
  return require("nexus-agent.core.block_registry").get_instance()
end

--- Namespace for our extmarks
local ns = vim.api.nvim_create_namespace("nexus_chat_render")

--- Common highlight groups (not per-block)
local function setup_common_hl()
  local chalk4 = "#666666"
  local chalk3 = "#999999"
  vim.api.nvim_set_hl(0, "NexusBlockDots", { fg = chalk4, italic = true })
  vim.api.nvim_set_hl(0, "NexusBlockDuration", { fg = chalk4, italic = true })
  vim.api.nvim_set_hl(0, "NexusBlockFoldIcon", { fg = chalk3 })
end

--- Format duration as human-readable string.
---@param seconds number
---@return string
local function format_duration(seconds)
  if seconds < 1 then
    return string.format("%dms", seconds * 1000)
  elseif seconds < 60 then
    return string.format("%.1fs", seconds)
  else
    local mins = math.floor(seconds / 60)
    local secs = seconds - mins * 60
    return string.format("%dm %ds", mins, secs)
  end
end

--- Append lines to the buffer (handles modifiable toggle).
---@param bufnr integer
---@param lines string[]
---@return integer start_line 0-indexed line where lines were inserted
local function buf_append(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return 0 end
  vim.bo[bufnr].modifiable = true
  local count = vim.api.nvim_buf_line_count(bufnr)
  local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
  local start_line
  if count == 1 and last == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    start_line = 0
  else
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    start_line = count
  end
  vim.bo[bufnr].modifiable = false
  return start_line
end

--- Append text (may be partial line) to the buffer, joining with last line.
---@param bufnr integer
---@param text string
local function buf_append_text(bufnr, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  local lines = vim.split(text, "\n", { plain = true })
  local count = vim.api.nvim_buf_line_count(bufnr)
  local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1] or ""

  if count == 1 and last == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    if #lines > 0 then
      local new_last = last .. lines[1]
      vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, { new_last })
      if #lines > 1 then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, vim.list_slice(lines, 2))
      end
    end
  end
  vim.bo[bufnr].modifiable = false
end

--- Scroll to bottom of buffer.
---@param winnr integer?
---@param bufnr integer
local function scroll_bottom(winnr, bufnr)
  if winnr and vim.api.nvim_win_is_valid(winnr) then
    local count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(winnr, { count, 0 })
  end
end

---@class nexus_chat.BlockState
---@field tag string Tag name
---@field attrs table Tag attributes
---@field start_line integer 0-indexed line where block header is
---@field content_start integer 0-indexed line where content begins
---@field end_line integer? 0-indexed line where block content ends (set on close)
---@field start_time number os.clock() when block opened
---@field header_extmark integer? Extmark ID for the header
---@field border_extmarks integer[] Extmark IDs for left border
---@field collapsed boolean Whether currently collapsed
---@field timer uv_timer_t? Animation timer
---@field dot_count integer Animation dot counter

---@class nexus_chat.RenderState
---@field bufnr integer Buffer number
---@field winnr integer? Window number
---@field block_stack nexus_chat.BlockState[] Stack of open blocks
---@field blocks nexus_chat.BlockState[] All blocks (open and closed)
local RenderState = {}
RenderState.__index = RenderState

--- Create a new render state for a buffer.
---@param bufnr integer
---@param winnr integer?
---@return nexus_chat.RenderState
function RenderState:new(bufnr, winnr)
  setup_common_hl()
  return setmetatable({
    bufnr = bufnr,
    winnr = winnr,
    block_stack = {},
    blocks = {},
  }, self)
end

--- Start the animated dots timer for a block.
---@param block nexus_chat.BlockState
function RenderState:_start_animation(block)
  local uv = vim.uv or vim.loop
  local registry = get_registry()
  local def = registry:get(block.tag)
  if not def then return end

  block.dot_count = 0
  block.timer = uv.new_timer()
  local bufnr = self.bufnr

  block.timer:start(0, 400, function()
    block.dot_count = (block.dot_count + 1) % 4
    local dots = string.rep(".", block.dot_count)

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        if block.timer then block.timer:close(); block.timer = nil end
        return
      end
      local label = def.active_label .. dots .. string.rep(" ", 3 - #dots)
      local hl = registry.hl_group(block.tag, "Header")

      if block.header_extmark then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.start_line, 0, {
          id = block.header_extmark,
          virt_text = {
            { def.icon, hl },
            { label, hl },
          },
          virt_text_pos = "overlay",
        })
      end
    end)
  end)
end

--- Stop animation timer for a block.
---@param block nexus_chat.BlockState
local function stop_animation(block)
  if block.timer then
    block.timer:close()
    block.timer = nil
  end
end

--- Update left border extmarks for a block's content region.
---@param block nexus_chat.BlockState
function RenderState:_update_borders(block)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  local registry = get_registry()

  -- Clear old borders
  for _, id in ipairs(block.border_extmarks or {}) do
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, ns, id)
  end
  block.border_extmarks = {}

  local end_line = vim.api.nvim_buf_line_count(self.bufnr) - 1
  local border_hl = registry.hl_group(block.tag, "Border")
  local bg_hl = registry.hl_group(block.tag, "Bg")

  for line = block.content_start, end_line do
    local id = vim.api.nvim_buf_set_extmark(self.bufnr, ns, line, 0, {
      sign_text = "▏",
      sign_hl_group = border_hl,
      line_hl_group = bg_hl,
    })
    block.border_extmarks[#block.border_extmarks + 1] = id
  end
end

--- Handle a tag_open event.
---@param event nexus_chat.ParserEvent
function RenderState:on_tag_open(event)
  vim.schedule(function()
    local registry = get_registry()
    local def = registry:get(event.tag)
    if not def then
      -- Unknown tag, just append the tag as text
      buf_append_text(self.bufnr, "<" .. event.tag .. ">")
      scroll_bottom(self.winnr, self.bufnr)
      return
    end

    local hl = registry.hl_group(event.tag, "Header")
    local hl_bg = registry.hl_group(event.tag, "HeaderBg")

    -- Add header line (blank, overlaid with virtual text)
    local header_line = buf_append(self.bufnr, { "", "" })

    -- Create header extmark
    local header_id = vim.api.nvim_buf_set_extmark(self.bufnr, ns, header_line, 0, {
      virt_text = {
        { def.icon, hl },
        { def.active_label, hl },
      },
      virt_text_pos = "overlay",
      line_hl_group = hl_bg,
    })

    local content_start = header_line + 1
    buf_append(self.bufnr, { "" })

    ---@type nexus_chat.BlockState
    local block = {
      tag = event.tag,
      attrs = event.attrs or {},
      start_line = header_line,
      content_start = content_start,
      start_time = os.clock(),
      header_extmark = header_id,
      border_extmarks = {},
      collapsed = false,
      timer = nil,
      dot_count = 0,
    }

    self.block_stack[#self.block_stack + 1] = block
    self.blocks[#self.blocks + 1] = block

    self:_start_animation(block)
    self:_update_borders(block)
    scroll_bottom(self.winnr, self.bufnr)
  end)
end

--- Handle a text event.
---@param event nexus_chat.ParserEvent
function RenderState:on_text(event)
  vim.schedule(function()
    local def = event.tag and get_registry():get(event.tag)

    -- If the block type has a custom content renderer, use it
    if def and def.render_content then
      def.render_content(self.bufnr, event.text, {})
    else
      buf_append_text(self.bufnr, event.text)
    end

    -- Update borders for the current block
    if #self.block_stack > 0 then
      local block = self.block_stack[#self.block_stack]
      self:_update_borders(block)
    end

    scroll_bottom(self.winnr, self.bufnr)
  end)
end

--- Handle a tag_close event.
---@param event nexus_chat.ParserEvent
function RenderState:on_tag_close(event)
  vim.schedule(function()
    local registry = get_registry()
    local def = registry:get(event.tag)

    -- Find and pop the matching block from stack
    local block
    for i = #self.block_stack, 1, -1 do
      if self.block_stack[i].tag == event.tag then
        block = self.block_stack[i]
        table.remove(self.block_stack, i)
        break
      end
    end

    if not block then return end

    stop_animation(block)

    local duration = os.clock() - block.start_time
    local duration_str = format_duration(duration)

    -- Record end_line before appending the trailing blank
    block.end_line = vim.api.nvim_buf_line_count(self.bufnr) - 1

    if def and block.header_extmark and vim.api.nvim_buf_is_valid(self.bufnr) then
      local hl = registry.hl_group(event.tag, "Header")
      local hl_bg = registry.hl_group(event.tag, "HeaderBg")

      -- Build final header: done_label + optional attr suffix + duration
      local suffix = ""
      if block.attrs and block.attrs.lang then
        suffix = " (" .. block.attrs.lang .. ")"
      elseif block.attrs and block.attrs.title then
        suffix = " — " .. block.attrs.title
      end

      pcall(vim.api.nvim_buf_set_extmark, self.bufnr, ns, block.start_line, 0, {
        id = block.header_extmark,
        virt_text = {
          { def.icon, hl },
          { def.done_label .. suffix, hl },
          { "  " .. duration_str, "NexusBlockDuration" },
        },
        virt_text_pos = "overlay",
        line_hl_group = hl_bg,
      })
    end

    buf_append(self.bufnr, { "" })
    self:_update_borders(block)

    -- Auto-collapse blocks with collapsed_default
    if def and def.collapsed_default then
      self:_collapse(block)
    end

    scroll_bottom(self.winnr, self.bufnr)
  end)
end

--- Process a batch of parser events.
---@param events nexus_chat.ParserEvent[]
function RenderState:process(events)
  for _, event in ipairs(events) do
    if event.type == "tag_open" then
      self:on_tag_open(event)
    elseif event.type == "text" then
      self:on_text(event)
    elseif event.type == "tag_close" then
      self:on_tag_close(event)
    end
  end
end

--- Clean up all timers.
function RenderState:destroy()
  for _, block in ipairs(self.blocks) do
    stop_animation(block)
  end
end

--- Update the window reference.
---@param winnr integer
function RenderState:set_winnr(winnr)
  self.winnr = winnr
end

--- Render a completed block synchronously (no animation, no vim.schedule).
--- Used for loading session history where blocks are already complete.
---@param tag string Block tag name (must be registered in BlockRegistry)
---@param content string Block content text
---@param attrs? table Tag attributes (e.g. { name = "Read", lang = "lua" })
---@param duration_str? string Pre-formatted duration string (e.g. "2.3s")
function RenderState:render_block(tag, content, attrs, duration_str)
  local registry = get_registry()
  local def = registry:get(tag)
  if not def then
    buf_append_text(self.bufnr, content)
    return
  end

  attrs = attrs or {}
  local hl = registry.hl_group(tag, "Header")
  local hl_bg = registry.hl_group(tag, "HeaderBg")

  -- Build suffix from attrs
  local suffix = ""
  if attrs.lang then suffix = " (" .. attrs.lang .. ")"
  elseif attrs.name then suffix = " — " .. attrs.name
  elseif attrs.title then suffix = " — " .. attrs.title
  end

  -- Header line
  local header_line = buf_append(self.bufnr, { "", "" })
  local header_id = vim.api.nvim_buf_set_extmark(self.bufnr, ns, header_line, 0, {
    virt_text = {
      { def.icon, hl },
      { def.done_label .. suffix, hl },
      { duration_str and ("  " .. duration_str) or "", "NexusBlockDuration" },
    },
    virt_text_pos = "overlay",
    line_hl_group = hl_bg,
  })

  -- Content
  local content_start = header_line + 1
  if content and content ~= "" then
    buf_append_text(self.bufnr, content)
  end
  buf_append(self.bufnr, { "" })

  -- Record end_line (current last line of buffer)
  local end_line = vim.api.nvim_buf_line_count(self.bufnr) - 1

  -- Store block state for fold toggle
  ---@type nexus_chat.BlockState
  local block = {
    tag = tag,
    attrs = attrs,
    start_line = header_line,
    content_start = content_start,
    end_line = end_line,
    start_time = 0,
    header_extmark = header_id,
    border_extmarks = {},
    collapsed = false,
    timer = nil,
    dot_count = 0,
  }
  self.blocks[#self.blocks + 1] = block
  self:_update_borders(block)

  -- Auto-collapse blocks with collapsed_default
  if def.collapsed_default then
    self:_collapse(block)
  end
end

--- Append lines to buffer synchronously (no vim.schedule).
--- Used for loading session history.
---@param lines string[]
function RenderState:append_lines(lines)
  buf_append(self.bufnr, lines)
end

--- Setup keymaps for block navigation and folding.
---@param bufnr integer
function RenderState:setup_keymaps(bufnr)
  vim.keymap.set("n", "<Tab>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1] - 1
    self:toggle_fold(line)
  end, { buffer = bufnr, desc = "Toggle nexus block fold" })

  vim.keymap.set("n", "]]", function()
    self:jump_block(1)
  end, { buffer = bufnr, desc = "Next block" })

  vim.keymap.set("n", "[[", function()
    self:jump_block(-1)
  end, { buffer = bufnr, desc = "Previous block" })

  -- Setup fold options on any window showing this buffer
  local winnr = self.winnr or vim.fn.bufwinid(bufnr)
  if winnr and winnr ~= -1 and vim.api.nvim_win_is_valid(winnr) then
    vim.wo[winnr].foldmethod = "manual"
    vim.wo[winnr].foldtext = "'   ▸ ' .. (v:foldend - v:foldstart) .. ' lines '"
    vim.wo[winnr].fillchars = "fold: "
    vim.wo[winnr].foldlevel = 99 -- start with everything open
    vim.wo[winnr].foldenable = true
  end
end

--- Find the block whose header or content spans the given line.
---@param line integer 0-indexed
---@return nexus_chat.BlockState?
function RenderState:_find_block(line)
  for _, block in ipairs(self.blocks) do
    local end_line = block.end_line or block.content_start
    if line >= block.start_line and line <= end_line then
      return block
    end
  end
  return nil
end

--- Collapse a block using Neovim manual folds.
---@param block nexus_chat.BlockState
function RenderState:_collapse(block)
  if not block.end_line or block.end_line <= block.content_start then return end
  local winnr = self.winnr or vim.fn.bufwinid(self.bufnr)
  if not winnr or winnr == -1 then return end

  local start_1 = block.content_start + 1  -- 1-indexed
  local end_1 = block.end_line + 1

  vim.api.nvim_win_call(winnr, function()
    -- Remove existing fold first to avoid nesting issues
    pcall(vim.cmd, start_1 .. "," .. end_1 .. "foldopen!")
    vim.cmd(start_1 .. "," .. end_1 .. "fold")
  end)
  block.collapsed = true
end

--- Expand a block fold.
---@param block nexus_chat.BlockState
function RenderState:_expand(block)
  if not block.end_line or block.end_line <= block.content_start then return end
  local winnr = self.winnr or vim.fn.bufwinid(self.bufnr)
  if not winnr or winnr == -1 then return end

  local start_1 = block.content_start + 1
  local end_1 = block.end_line + 1

  vim.api.nvim_win_call(winnr, function()
    pcall(vim.cmd, start_1 .. "," .. end_1 .. "foldopen!")
  end)
  block.collapsed = false
end

--- Jump to the next or previous block header.
---@param direction integer 1 for next, -1 for previous
function RenderState:jump_block(direction)
  if #self.blocks == 0 then return end
  local winnr = self.winnr or vim.fn.bufwinid(self.bufnr)
  if not winnr or winnr == -1 then return end

  local cursor = vim.api.nvim_win_get_cursor(winnr)[1] - 1 -- 0-indexed

  if direction == 1 then
    for _, block in ipairs(self.blocks) do
      if block.start_line > cursor then
        vim.api.nvim_win_set_cursor(winnr, { block.start_line + 1, 0 })
        return
      end
    end
  else
    for i = #self.blocks, 1, -1 do
      if self.blocks[i].start_line < cursor then
        vim.api.nvim_win_set_cursor(winnr, { self.blocks[i].start_line + 1, 0 })
        return
      end
    end
  end
end

--- Toggle fold for the block at the given line.
---@param line integer 0-indexed
function RenderState:toggle_fold(line)
  local block = self:_find_block(line)
  if not block then return end

  if block.collapsed then
    self:_expand(block)
  else
    self:_collapse(block)
  end
end

-- Exports
M.RenderState = RenderState

--- Create a new render state.
---@param bufnr integer
---@param winnr integer?
---@return nexus_chat.RenderState
function M.new(bufnr, winnr)
  return RenderState:new(bufnr, winnr)
end

return M
