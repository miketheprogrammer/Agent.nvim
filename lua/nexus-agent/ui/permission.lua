local Permission = {}
Permission.__index = Permission

function Permission:new()
  return setmetatable({
    _bufnr = nil,
    _winnr = nil,
    _callback = nil,
  }, self)
end

--- Show a permission prompt in a floating window
--- @param tool_name string
--- @param tool_input table
--- @param on_result fun(allowed: boolean)
function Permission:prompt(tool_name, tool_input, on_result)
  self._callback = on_result

  -- Create floating window content
  local lines = {
    "  Permission Request  ",
    "",
    "  Tool: " .. tool_name,
    "",
    "  Input:",
  }

  -- Add truncated input preview
  local input_str = vim.inspect(tool_input)
  for _, line in ipairs(vim.split(input_str:sub(1, 300), "\n")) do
    table.insert(lines, "  " .. line)
  end

  table.insert(lines, "")
  table.insert(lines, "  [y] Allow  [n] Deny  [!] Allow All")

  -- Create buf + floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"

  local width = 60
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Nexus Agent ",
    title_pos = "center",
  })

  self._bufnr = buf
  self._winnr = win

  -- Set keymaps
  local function close_and_respond(allowed)
    self:close()
    if self._callback then self._callback(allowed) end
  end

  vim.keymap.set("n", "y", function() close_and_respond(true) end, { buffer = buf })
  vim.keymap.set("n", "a", function() close_and_respond(true) end, { buffer = buf })
  vim.keymap.set("n", "n", function() close_and_respond(false) end, { buffer = buf })
  vim.keymap.set("n", "!", function() close_and_respond(true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() close_and_respond(false) end, { buffer = buf })
  vim.keymap.set("n", "q", function() close_and_respond(false) end, { buffer = buf })
end

--- Close the permission window
function Permission:close()
  if self._winnr and vim.api.nvim_win_is_valid(self._winnr) then
    vim.api.nvim_win_close(self._winnr, true)
  end
  if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
    vim.api.nvim_buf_delete(self._bufnr, { force = true })
  end
  self._winnr = nil
  self._bufnr = nil
end

return Permission
