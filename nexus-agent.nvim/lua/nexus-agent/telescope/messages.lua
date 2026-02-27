--- Telescope picker for nexus-agent session messages.
--- Shows message history with preview and copy/buffer actions.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

--- Extract display text from a message based on its type and content.
---@param msg table
---@return string label, string text
local function format_message(msg)
  local msg_type = msg.type or "unknown"

  if msg_type == "user" then
    local text = type(msg.content) == "string" and msg.content or "(complex content)"
    return "[user]", text
  elseif msg_type == "assistant" then
    if type(msg.content) == "table" then
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          return "[assistant]", block.text or ""
        elseif block.type == "tool_use" then
          return "[tool:" .. (block.name or "?") .. "]", vim.json.encode(block.input or {})
        end
      end
    end
    return "[assistant]", "(no text content)"
  elseif msg_type == "result" then
    return "[result]", msg.result or "(completed)"
  elseif msg_type == "system" then
    return "[system]", type(msg.content) == "string" and msg.content or ""
  end

  return "[" .. msg_type .. "]", ""
end

--- Get the full text content of a message for preview.
---@param msg table
---@return string[]
local function full_message_lines(msg)
  local lines = {}
  local msg_type = msg.type or "unknown"
  table.insert(lines, "Type: " .. msg_type)

  if msg.model then
    table.insert(lines, "Model: " .. msg.model)
  end
  if msg.stop_reason then
    table.insert(lines, "Stop reason: " .. msg.stop_reason)
  end
  if msg.duration_ms then
    table.insert(lines, "Duration: " .. tostring(msg.duration_ms) .. "ms")
  end
  if msg.cost_usd then
    table.insert(lines, "Cost: $" .. string.format("%.4f", msg.cost_usd))
  end
  if msg.num_turns then
    table.insert(lines, "Turns: " .. tostring(msg.num_turns))
  end

  table.insert(lines, "")
  table.insert(lines, "--- Content ---")

  if type(msg.content) == "string" then
    for line in msg.content:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
  elseif type(msg.content) == "table" then
    for _, block in ipairs(msg.content) do
      if block.type == "text" then
        table.insert(lines, "")
        for line in (block.text or ""):gmatch("[^\n]+") do
          table.insert(lines, line)
        end
      elseif block.type == "thinking" then
        table.insert(lines, "")
        table.insert(lines, "[thinking]")
        for line in (block.thinking or ""):gmatch("[^\n]+") do
          table.insert(lines, line)
        end
      elseif block.type == "tool_use" then
        table.insert(lines, "")
        table.insert(lines, "[tool_use: " .. (block.name or "?") .. "]")
        local ok, json = pcall(vim.json.encode, block.input or {})
        if ok then
          table.insert(lines, json)
        end
      elseif block.type == "tool_result" then
        table.insert(lines, "")
        table.insert(lines, "[tool_result]")
        local content = block.content
        if type(content) == "string" then
          for line in content:gmatch("[^\n]+") do
            table.insert(lines, line)
          end
        end
      end
    end
  elseif msg.result then
    for line in msg.result:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
  end

  return lines
end

function M.messages(opts)
  opts = opts or {}
  local session_id = opts.session_id

  if not session_id then
    vim.notify("No session_id provided", vim.log.levels.WARN)
    return
  end

  local store = require("nexus-agent.session.store"):new()
  local history = require("nexus-agent.session.history"):new(store)
  local messages = history:read(session_id)

  if #messages == 0 then
    vim.notify("No messages found for session " .. session_id, vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Session Messages",
    finder = finders.new_table({
      results = messages,
      entry_maker = function(msg)
        local label, text = format_message(msg)
        local short = text:sub(1, 80):gsub("\n", " ")
        local display = label .. " " .. short
        return {
          value = msg,
          display = display,
          ordinal = label .. " " .. text,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Message Content",
      define_preview = function(self, entry, status)
        local lines = full_message_lines(entry.value)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local lines = full_message_lines(entry.value)
          vim.fn.setreg("+", table.concat(lines, "\n"))
          vim.notify("Message copied to clipboard", vim.log.levels.INFO)
        end
      end)
      map("i", "<C-y>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local _, text = format_message(entry.value)
          vim.fn.setreg('"', text)
          vim.notify("Message yanked to unnamed register", vim.log.levels.INFO)
        end
      end)
      map("i", "<C-b>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local lines = full_message_lines(entry.value)
          local buf = vim.api.nvim_create_buf(true, true)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.bo[buf].filetype = "markdown"
          vim.bo[buf].bufhidden = "wipe"
          vim.api.nvim_set_current_buf(buf)
        end
      end)
      return true
    end,
  }):find()
end

return M
