local ChatBuffer = {}
ChatBuffer.__index = ChatBuffer

local ns_id = vim.api.nvim_create_namespace("nexus_agent")

--- Find an existing buffer by name, or nil.
---@param name string
---@return integer?
local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return nil
end

function ChatBuffer:new(name)
  name = name or "nexus://chat"

  -- Reuse existing buffer with this name if it exists
  local bufnr = find_buf_by_name(name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false

  return setmetatable({
    _bufnr = bufnr,
    _winnr = nil,
    _ns_id = ns_id,
    _is_streaming = false,
    _status = "idle",
  }, self)
end

--- Find an existing window displaying this buffer, or nil.
---@return integer?
function ChatBuffer:_find_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == self._bufnr then
      return w
    end
  end
  return nil
end

--- Open the buffer in a split window. Reuses existing window if already visible.
--- @param direction "right"|"below"|nil (default "right")
function ChatBuffer:open(direction)
  -- If buffer is already visible in a window, just focus it
  local existing = self:_find_win()
  if existing then
    vim.api.nvim_set_current_win(existing)
    self._winnr = existing
    return self
  end

  direction = direction or "right"
  if direction == "right" then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
  local winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winnr, self._bufnr)
  self._winnr = winnr
  -- Set window options
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
  vim.wo[winnr].number = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn = "yes:1"
  vim.wo[winnr].foldmethod = "manual"
  vim.wo[winnr].foldenable = true
  vim.wo[winnr].foldlevel = 99
  return self
end

--- Append text to buffer (streaming-safe, called from libuv)
--- @param text string
function ChatBuffer:append(text)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    vim.bo[self._bufnr].modifiable = true
    local lines = vim.split(text, "\n", { plain = true })
    -- If buffer is empty and first line is empty, replace it
    local line_count = vim.api.nvim_buf_line_count(self._bufnr)
    local last_line = vim.api.nvim_buf_get_lines(self._bufnr, -2, -1, false)[1] or ""

    if last_line == "" and line_count == 1 then
      vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    else
      -- Append first chunk to last line, rest as new lines
      if #lines > 0 then
        local new_last = last_line .. lines[1]
        vim.api.nvim_buf_set_lines(self._bufnr, -2, -1, false, { new_last })
        if #lines > 1 then
          vim.api.nvim_buf_set_lines(self._bufnr, -1, -1, false, vim.list_slice(lines, 2))
        end
      end
    end
    vim.bo[self._bufnr].modifiable = false
    -- Auto-scroll to bottom
    if self._winnr and vim.api.nvim_win_is_valid(self._winnr) then
      local new_count = vim.api.nvim_buf_line_count(self._bufnr)
      vim.api.nvim_win_set_cursor(self._winnr, { new_count, 0 })
    end
  end)
end

--- Append a separator line
function ChatBuffer:separator()
  self:_append_lines({ "", "---", "" })
end

--- Append a user message header
function ChatBuffer:user_header(prompt)
  self:_append_lines({ "", "## > " .. prompt, "" })
end

--- Append an assistant header
function ChatBuffer:assistant_header()
  self:_append_lines({ "", "## Assistant", "" })
end

--- Append tool use indicator with extmarks
function ChatBuffer:append_tool_use(tool_name, tool_input)
  local input_preview = vim.inspect(tool_input):sub(1, 100)
  self:_append_lines({ "", "**Tool: " .. tool_name .. "**", "```", input_preview, "```", "" })
end

--- Append tool result
function ChatBuffer:append_tool_result(tool_name, result, is_error)
  local prefix = is_error and "**Error" or "**Result"
  self:_append_lines({ prefix .. " (" .. tool_name .. "):**", "```", result:sub(1, 500), "```", "" })
end

--- Set status text at top of buffer using extmarks
function ChatBuffer:set_status(status)
  self._status = status
  -- Could use virtual text extmark at line 0
end

--- Clear the buffer
function ChatBuffer:clear()
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, { "" })
    vim.bo[self._bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_id, 0, -1)
  end)
end

function ChatBuffer:bufnr() return self._bufnr end
function ChatBuffer:winnr() return self._winnr end
function ChatBuffer:is_streaming() return self._is_streaming end

function ChatBuffer:close()
  if self._winnr and vim.api.nvim_win_is_valid(self._winnr) then
    -- Don't close the last window — switch to a new buffer instead
    local wins = vim.api.nvim_list_wins()
    if #wins <= 1 then
      vim.cmd("enew")
    else
      vim.api.nvim_win_close(self._winnr, true)
    end
    self._winnr = nil
  end
end

--- Internal: append lines with modifiable toggle
function ChatBuffer:_append_lines(lines)
  -- Flatten: split any element that contains embedded newlines
  local flat = {}
  for _, item in ipairs(lines) do
    for line in (item .. "\n"):gmatch("([^\n]*)\n") do
      flat[#flat + 1] = line
    end
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    vim.bo[self._bufnr].modifiable = true
    local count = vim.api.nvim_buf_line_count(self._bufnr)
    local last = vim.api.nvim_buf_get_lines(self._bufnr, -2, -1, false)[1]
    if count == 1 and last == "" then
      vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, flat)
    else
      vim.api.nvim_buf_set_lines(self._bufnr, -1, -1, false, flat)
    end
    vim.bo[self._bufnr].modifiable = false
    if self._winnr and vim.api.nvim_win_is_valid(self._winnr) then
      local new_count = vim.api.nvim_buf_line_count(self._bufnr)
      vim.api.nvim_win_set_cursor(self._winnr, { new_count, 0 })
    end
  end)
end

return ChatBuffer
