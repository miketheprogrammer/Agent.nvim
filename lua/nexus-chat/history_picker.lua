--- Telescope picker for nexus-chat message history.
--- Shows all raw messages with JSON preview.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

--- Format a timestamp for display.
---@param ts number?
---@return string
local function fmt_time(ts)
  if not ts then return "" end
  return os.date("%H:%M:%S", ts)
end

--- Build a one-line display string for a message.
---@param msg table
---@param idx integer
---@return string display
---@return string ordinal
local function format_entry(msg, idx)
  local t = msg.type or "?"
  local time = fmt_time(msg.timestamp)
  local summary = ""

  if t == "user" then
    local c = type(msg.content) == "string" and msg.content or ""
    summary = c:sub(1, 60):gsub("\n", " ")
  elseif t == "assistant" then
    if type(msg.content) == "table" then
      for _, block in ipairs(msg.content) do
        if block.type == "text" and block.text and block.text ~= "" then
          summary = block.text:sub(1, 60):gsub("\n", " ")
          break
        elseif block.type == "tool_use" then
          summary = "tool:" .. (block.name or "?")
          break
        elseif block.type == "thinking" then
          summary = "(thinking) " .. (block.thinking or ""):sub(1, 40):gsub("\n", " ")
          break
        end
      end
    end
  elseif t == "result" then
    summary = (msg.result or ""):sub(1, 60):gsub("\n", " ")
  elseif t == "stream_event" then
    summary = (msg.event_type or "")
  elseif t == "system" then
    summary = type(msg.content) == "string" and msg.content:sub(1, 60):gsub("\n", " ") or ""
  elseif t == "control_request" or t == "control_response" then
    summary = vim.inspect(msg.request or msg.response or {}):sub(1, 60):gsub("\n", " ")
  end

  local display = string.format("%3d  %s  %-18s  %s", idx, time, t, summary)
  return display, t .. " " .. summary
end

--- Pretty-print a table as indented JSON lines.
---@param tbl table
---@return string[]
local function pretty_json_lines(tbl)
  local ok, json = pcall(vim.json.encode, tbl)
  if not ok then
    return { "-- failed to encode --", vim.inspect(tbl) }
  end
  -- Re-decode and use vim.inspect for readable formatting,
  -- but also show the raw JSON
  local lines = {}
  table.insert(lines, "--- Raw JSON ---")
  table.insert(lines, "")
  -- Split long JSON into readable chunks
  -- Try pretty-printing with vim.json.decode + vim.inspect
  local ok2, decoded = pcall(vim.json.decode, json)
  if ok2 then
    for line in vim.inspect(decoded):gmatch("[^\n]+") do
      table.insert(lines, line)
    end
  else
    table.insert(lines, json)
  end
  return lines
end

--- Open the history picker.
---@param messages table[] The message array from chat state
function M.pick(messages, opts)
  opts = opts or {}

  if #messages == 0 then
    vim.notify("No messages in history", vim.log.levels.INFO)
    return
  end

  -- Build entries with index (newest last in the list, but we'll show all)
  local entries = {}
  for i, msg in ipairs(messages) do
    entries[#entries + 1] = { idx = i, msg = msg }
  end

  pickers.new(opts, {
    prompt_title = "Chat History (" .. #entries .. " messages)",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(item)
        local display, ordinal = format_entry(item.msg, item.idx)
        return {
          value = item,
          display = display,
          ordinal = ordinal,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Raw Message",
      define_preview = function(self, entry)
        local msg = entry.value.msg
        local lines = pretty_json_lines(msg)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "lua"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- <CR> opens raw message in a scratch buffer
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end

        local msg = entry.value.msg
        local lines = pretty_json_lines(msg)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].filetype = "lua"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].modifiable = false
        vim.cmd("vsplit")
        vim.api.nvim_win_set_buf(0, buf)
      end)

      -- <C-y> copy raw JSON to clipboard
      map("i", "<C-y>", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local ok, json = pcall(vim.json.encode, entry.value.msg)
        if ok then
          vim.fn.setreg("+", json)
          vim.notify("Raw JSON copied to clipboard", vim.log.levels.INFO)
        end
      end)

      -- <C-d> filter: only show non-stream_event messages
      map("i", "<C-d>", function()
        -- Close and re-open with filtered list
        actions.close(prompt_bufnr)
        local filtered = {}
        for _, item in ipairs(entries) do
          if item.msg.type ~= "stream_event" then
            filtered[#filtered + 1] = item
          end
        end
        M._pick_entries(filtered, opts)
      end)

      return true
    end,
  }):find()
end

--- Internal: pick from pre-built entries (for filtering).
function M._pick_entries(entries, opts)
  pickers.new(opts, {
    prompt_title = "Chat History — filtered (" .. #entries .. " messages)",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(item)
        local display, ordinal = format_entry(item.msg, item.idx)
        return {
          value = item,
          display = display,
          ordinal = ordinal,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Raw Message",
      define_preview = function(self, entry)
        local msg = entry.value.msg
        local lines = pretty_json_lines(msg)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "lua"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local lines = pretty_json_lines(entry.value.msg)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].filetype = "lua"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].modifiable = false
        vim.cmd("vsplit")
        vim.api.nvim_win_set_buf(0, buf)
      end)
      return true
    end,
  }):find()
end

return M
