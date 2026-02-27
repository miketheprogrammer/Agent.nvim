--- Telescope picker for browsing Claude CLI sessions and their chat history.
--- Scans ~/.claude/projects/ for JSONL session files.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local scanner = require("nexus-chat.session_scanner")

local M = {}

--- Format a timestamp for display.
---@param ts number?
---@return string
local function fmt_time(ts)
  if not ts then return "" end
  -- Handle millisecond timestamps
  if ts > 1e12 then ts = math.floor(ts / 1000) end
  local now = os.time()
  local diff = now - ts
  if diff < 86400 then
    return os.date("%H:%M", ts)
  elseif diff < 86400 * 7 then
    return os.date("%a %H:%M", ts)
  else
    return os.date("%b %d", ts)
  end
end

--- Format file size for display.
---@param bytes number
---@return string
local function fmt_size(bytes)
  if bytes < 1024 then return bytes .. "B" end
  if bytes < 1024 * 1024 then return string.format("%.0fK", bytes / 1024) end
  return string.format("%.1fM", bytes / 1024 / 1024)
end

--- Shorten a model name for display.
---@param model string?
---@return string
local function short_model(model)
  if not model then return "?" end
  if model:match("opus") then return "opus" end
  if model:match("sonnet") then return "sonnet" end
  if model:match("haiku") then return "haiku" end
  return model:sub(1, 12)
end

--- Render conversation messages into preview lines.
---@param messages table[]
---@return string[]
local function render_conversation(messages)
  local lines = {}
  for _, msg in ipairs(messages) do
    local role = msg.role == "user" and "▶ You" or "◀ Assistant"
    local ts = ""
    if msg.timestamp then
      local t = msg.timestamp
      if type(t) == "string" then
        -- ISO 8601 → extract time directly
        local h, mi, s = t:match("T(%d+):(%d+):(%d+)")
        if h then ts = " (" .. h .. ":" .. mi .. ":" .. s .. ")" end
      elseif type(t) == "number" then
        if t > 1e12 then t = math.floor(t / 1000) end
        ts = " (" .. os.date("%H:%M:%S", t) .. ")"
      end
    end
    lines[#lines + 1] = role .. ts
    lines[#lines + 1] = string.rep("─", 40)

    -- Wrap content lines
    local content = msg.content or ""
    -- Truncate very long messages
    if #content > 2000 then
      content = content:sub(1, 2000) .. "\n... (truncated)"
    end
    for line in content:gmatch("[^\n]*") do
      lines[#lines + 1] = "  " .. line
    end
    lines[#lines + 1] = ""
  end
  return lines
end

--- Open the sessions picker.
---@param opts? { project?: string, limit?: integer }
function M.pick(opts)
  opts = opts or {}

  local sessions = scanner.scan({
    limit = opts.limit or 100,
    project = opts.project,
  })

  if #sessions == 0 then
    vim.notify("No sessions found", vim.log.levels.INFO)
    return
  end

  -- Cache for conversation previews (session path → lines)
  local preview_cache = {}

  pickers.new(opts, {
    prompt_title = "Chat Sessions (" .. #sessions .. ")",
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(session)
        local time = fmt_time(session.timestamp)
        local model = short_model(session.model)
        local prompt = session.prompt ~= "" and session.prompt or "(no prompt)"
        local project = session.project or "?"
        -- Decode project name: replace -- with :\ and - with \
        local display_project = project:gsub("^(%a)%-%-", "%1:\\"):gsub("%-", "\\")
        local size = fmt_size(session.size or 0)

        local display = string.format(
          "%-8s  %-7s  %-6s  %-20s  %s",
          time, model, size, display_project:sub(1, 20), prompt:sub(1, 80)
        )

        return {
          value = session,
          display = display,
          ordinal = time .. " " .. model .. " " .. project .. " " .. prompt,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Conversation",
      define_preview = function(self, entry)
        local session = entry.value

        -- Check cache
        if preview_cache[session.path] then
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_cache[session.path])
          vim.bo[self.state.bufnr].filetype = "markdown"
          return
        end

        -- Show loading indicator
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Loading conversation..." })

        -- Read conversation asynchronously-ish (still blocking but separate from entry)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(self.state.bufnr) then return end

          local header = {
            "Session: " .. (session.session_id or session.id),
            "Project: " .. (session.project or "?"),
            "Model:   " .. (session.model or "?"),
            "CWD:     " .. (session.cwd or "?"),
            "Branch:  " .. (session.branch or "?"),
            "Slug:    " .. (session.slug or "?"),
            "Size:    " .. fmt_size(session.size or 0),
            "",
            string.rep("═", 50),
            "",
          }

          local messages = scanner.read_conversation(session.path, { max_lines = 200 })
          local conv_lines = render_conversation(messages)

          local all_lines = {}
          for _, l in ipairs(header) do all_lines[#all_lines + 1] = l end
          for _, l in ipairs(conv_lines) do all_lines[#all_lines + 1] = l end

          if #messages == 0 then
            all_lines[#all_lines + 1] = "(No user/assistant messages found in first 200 lines)"
          end

          preview_cache[session.path] = all_lines

          if vim.api.nvim_buf_is_valid(self.state.bufnr) then
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, all_lines)
            vim.bo[self.state.bufnr].filetype = "markdown"
          end
        end)
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- <CR>: Load session history into NexusChat
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        require("nexus-chat").load_session(entry.value)
      end)

      -- <C-o>: Open raw JSONL in a buffer
      map("i", "<C-o>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        vim.cmd("edit " .. vim.fn.fnameescape(entry.value.path))
      end)

      -- <C-y>: Copy session ID to clipboard
      map("i", "<C-y>", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local id = entry.value.session_id or entry.value.id
        vim.fn.setreg("+", id)
        vim.notify("Session ID copied: " .. id, vim.log.levels.INFO)
      end)

      -- <C-p>: Filter by project
      map("i", "<C-p>", function()
        actions.close(prompt_bufnr)
        local projects = scanner.list_projects()
        vim.ui.select(projects, { prompt = "Filter by project:" }, function(choice)
          if choice then
            M.pick(vim.tbl_extend("force", opts, { project = choice }))
          end
        end)
      end)

      return true
    end,
  }):find()
end

return M
