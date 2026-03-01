local M = {}

-- Lazy-loaded dependencies
local ChatBuffer, xml_parser, renderer_mod, chat_agent_mod

local function ensure_deps()
  if not ChatBuffer then
    ChatBuffer = require("nexus-agent.ui.chat_buffer")
    xml_parser = require("nexus-chat.xml_parser")
    renderer_mod = require("nexus-chat.renderer")
    chat_agent_mod = require("nexus-chat.agent")
  end
end

-- Available models for the picker
local MODELS = {
  { id = "sonnet", label = "Sonnet", icon = "󰧑 " },
  { id = "opus", label = "Opus", icon = "󰁯 " },
  { id = "haiku", label = "Haiku", icon = "󰉀 " },
}

-- Chat state
local state = {
  chat_buf = nil,       ---@type table? ChatBuffer instance
  input_buf = nil,      ---@type integer? Buffer number for input
  input_win = nil,      ---@type integer? Window for input (floating)
  agent = nil,          ---@type table? Agent instance
  session = nil,        ---@type table? Current session handle
  session_id = nil,     ---@type string? Active session ID for multi-turn
  model = "sonnet",     ---@type string Active model short name
  agent_def = nil,      ---@type table? Active agent definition (nil = default chat agent)
  agent_name = nil,     ---@type string? Display name of active agent (nil = "Chat")
  parser = nil,         ---@type nexus_chat.StreamParser? Streaming XML parser
  render = nil,         ---@type nexus_chat.RenderState? Render state
  cwd = nil,            ---@type string? Working directory for the Claude subprocess
  messages = {},        ---@type table[] Raw messages from the transport (all types)
  _input_keymaps_set = false, ---@type boolean Whether keymaps have been bound
}

--- Find an existing window displaying a buffer, or nil.
---@param bufnr integer
---@return integer?
local function find_win_for_buf(bufnr)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
  return nil
end

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

--- Get display label for the current model.
---@return string
local function model_label()
  for _, m in ipairs(MODELS) do
    if m.id == state.model then return m.icon .. m.label end
  end
  return state.model
end

--- Build the title spans for the floating input.
---@return table[] title config for nvim_open_win / nvim_win_set_config
local function build_title()
  local agent_name = state.agent_name or "Chat"
  return {
    { " " .. agent_name .. " ", "NexusChatInputTitle" },
    { " " .. model_label() .. " ", "NexusChatInputModel" },
    { " " .. vim.fn.fnamemodify(state.cwd or "", ":t") .. " ", "NexusChatInputCwd" },
  }
end

--- Update the floating input window title to reflect the current agent/model.
local function update_input_title()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_win_set_config(state.input_win, {
      title = build_title(),
      title_pos = "left",
    })
  end
end

--- Build an agent instance from a saved definition, or the default chat agent.
---@param def? table Saved agent JSON definition (nil = default chat agent)
---@param model string Short model name
---@return table agent
local function build_agent(def, model)
  ensure_deps()
  -- Default chat agent (with XML tag instructions)
  if not def and state.agent_name == "Chat" then
    return chat_agent_mod.create(model, state.cwd)
  end

  -- Raw agent — no definition, no special instructions
  if not def then
    local nexus = require("nexus-agent.api")
    local builder = nexus.agent()
      :name("raw")
      :model(model)
      :max_turns(25)
    if state.cwd then builder:cwd(state.cwd) end
    return builder:build()
  end

  -- Custom agent — build from definition
  local nexus = require("nexus-agent.api")
  local builder = nexus.agent()
    :name(def.name or "custom")
    :description(def.description or "")
    :model(model)
    :permission_mode(def.permission_mode or "acceptEdits")
    :max_turns(def.max_turns or 25)

  if state.cwd then
    builder:cwd(state.cwd)
  end

  if def.system_prompt and def.system_prompt ~= "" then
    builder:system_prompt(def.system_prompt)
  end

  if def.instructions then
    for _, inst in ipairs(def.instructions) do
      builder:instruction(inst)
    end
  end

  if def.tools then
    for _, t in ipairs(def.tools) do
      builder:tool(t)
    end
  end

  return builder:build()
end

--- Setup the chat plugin
function M.setup(opts)
  opts = opts or {}
  ensure_deps()
  if opts.model then state.model = opts.model end
  if not state.cwd then state.cwd = vim.fn.getcwd() end
  state.agent_name = "Chat"
  state.agent = build_agent(nil, state.model)
end

--- Switch the active model. Recreates the agent with the new model.
---@param model_id string Short model name ("sonnet", "opus", "haiku")
function M.set_model(model_id)
  state.model = model_id
  state.agent = build_agent(state.agent_def, state.model)
  update_input_title()
end

--- Switch the active agent definition.
---@param def? table Saved agent JSON (nil = default chat agent)
---@param name? string Display name (nil = "Chat")
function M.set_agent(def, name)
  state.agent_def = def
  state.agent_name = name
  -- If the agent def specifies a model, use it
  if def and def.model then
    state.model = def.model
  end
  state.agent = build_agent(def, state.model)
  update_input_title()
end

--- Load saved agent definitions from disk.
---@return table[] List of { name, description, model, ... }
local function load_saved_agents()
  local agents_dir = vim.fn.expand("~") .. "/.cache/nvim/nexus-agent/agents"
  vim.fn.mkdir(agents_dir, "p")
  local files = vim.fn.glob(agents_dir .. "/*.json", false, true)
  local agents = {}
  for _, file in ipairs(files) do
    local content = table.concat(vim.fn.readfile(file), "\n")
    local ok, def = pcall(vim.json.decode, content)
    if ok and def.name then
      table.insert(agents, def)
    end
  end
  return agents
end

--- Open the agent picker (Telescope).
function M.pick_agent()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local action_set = require("telescope.actions.set")
  local previewers = require("telescope.previewers")

  local saved = load_saved_agents()

  -- Prepend "No Agent (Claude Code)" as first entry
  local entries = {}
  table.insert(entries, {
    def = nil,
    name = "Chat",
    display_name = "󰭹  Default Chat",
    description = "Default nexus-chat agent with XML tags",
    is_default = true,
  })
  table.insert(entries, {
    def = nil,
    name = nil,
    display_name = "  Claude Code (no agent)",
    description = "Raw Claude Code — no system prompt or instructions",
    is_none = true,
  })
  for _, def in ipairs(saved) do
    table.insert(entries, {
      def = def,
      name = def.name,
      display_name = "  " .. def.name,
      description = def.description or "",
    })
  end

  pickers.new({}, {
    prompt_title = "Select Agent",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        local marker = ""
        if e.is_default and not state.agent_def and state.agent_name ~= nil then
          marker = " *"
        elseif e.is_none and not state.agent_def and state.agent_name == nil then
          marker = " *"
        elseif e.name and e.name == state.agent_name then
          marker = " *"
        end
        return {
          value = e,
          display = e.display_name .. marker .. "  " .. e.description,
          ordinal = (e.name or "default") .. " " .. e.description,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Agent Config",
      define_preview = function(self, entry)
        local e = entry.value
        local lines = {}
        if e.is_default then
          lines = {
            "# Default Chat Agent",
            "",
            "The built-in nexus-chat agent with XML tag instructions.",
            "Includes <thinking>, <response>, <code>, <shell> tags.",
          }
        elseif e.is_none then
          lines = {
            "# Claude Code (no agent)",
            "",
            "Uses Claude Code with no system prompt override.",
            "Raw model output — no XML tags or structured formatting.",
          }
        elseif e.def then
          lines = {
            "# " .. (e.def.name or "?"),
            "",
            "**Model:** " .. (e.def.model or "sonnet"),
            "**Permission Mode:** " .. (e.def.permission_mode or "acceptEdits"),
            "**Max Turns:** " .. tostring(e.def.max_turns or 25),
            "",
            "## System Prompt",
            "",
          }
          -- Split system prompt into individual lines (nvim_buf_set_lines can't handle embedded newlines)
          for _, pl in ipairs(vim.split(e.def.system_prompt or "(none)", "\n", { plain = true })) do
            table.insert(lines, pl)
          end
          if e.def.instructions and #e.def.instructions > 0 then
            table.insert(lines, "")
            table.insert(lines, "## Instructions")
            for _, inst in ipairs(e.def.instructions) do
              table.insert(lines, "- " .. inst)
            end
          end
          if e.def.tools and #e.def.tools > 0 then
            table.insert(lines, "")
            table.insert(lines, "## Tools")
            for _, t in ipairs(e.def.tools) do
              table.insert(lines, "- " .. t)
            end
          end
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local e = entry.value
        if e.is_default then
          M.set_agent(nil, "Chat")
        elseif e.is_none then
          M.set_agent(nil, nil)
        else
          M.set_agent(e.def, e.name)
        end
      end)

      -- <C-e>: Edit agent definition
      map("i", "<C-e>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry and entry.value.def then
          require("nexus-agent.ui.agent_editor"):new():open(entry.value.def)
        end
      end)

      -- <C-n>: Create new agent
      map("i", "<C-n>", function()
        actions.close(prompt_bufnr)
        require("nexus-agent.ui.agent_editor"):new():open()
      end)

      return true
    end,
  }):find()
end

--- Open the model picker (Telescope).
function M.pick_model()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Select Model",
    finder = finders.new_table({
      results = MODELS,
      entry_maker = function(m)
        local marker = m.id == state.model and " *" or ""
        return {
          value = m,
          display = m.icon .. m.label .. marker,
          ordinal = m.label,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then M.set_model(entry.value.id) end
      end)
      return true
    end,
  }):find()
end

--- Type '@' then open a file picker; insert the chosen filename after the '@'.
--- On cancel the bare '@' is left in the buffer.
local function pick_file_mention()
  local input_win = state.input_win
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then return end
  local buf = state.input_buf

  -- Insert '@' at the current cursor position
  local pos = vim.api.nvim_win_get_cursor(input_win)
  local row, col = pos[1] - 1, pos[2]
  vim.api.nvim_buf_set_text(buf, row, col, row, col, { "@" })
  local after_at = col + 1

  vim.cmd("stopinsert")

  require("telescope.builtin").find_files({
    attach_mappings = function(prompt_bufnr)
      local actions     = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
          vim.api.nvim_set_current_win(state.input_win)
        end
        if not entry then
          vim.cmd("startinsert")
          return
        end
        local filename = entry.value
        vim.api.nvim_buf_set_text(buf, row, after_at, row, after_at, { filename })
        vim.api.nvim_win_set_cursor(state.input_win, { row + 1, after_at + #filename })
        vim.cmd("startinsert")
      end)

      return true
    end,
  })
end

--- Type '#' then open a live-grep picker; insert '@filepath:linenum' on select.
--- On cancel the bare '#' is left in the buffer.
local function pick_grep_mention()
  local input_win = state.input_win
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then return end
  local buf = state.input_buf

  local pos = vim.api.nvim_win_get_cursor(input_win)
  local row, col = pos[1] - 1, pos[2]
  vim.api.nvim_buf_set_text(buf, row, col, row, col, { "#" })
  local after_hash = col + 1

  vim.cmd("stopinsert")

  require("telescope.builtin").live_grep({
    attach_mappings = function(prompt_bufnr)
      local actions      = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
          vim.api.nvim_set_current_win(state.input_win)
        end
        if not entry then
          vim.cmd("startinsert")
          return
        end
        -- entry.filename + entry.lnum from live_grep results
        local mention = "@" .. entry.filename .. ":" .. (entry.lnum or 1)
        -- Replace the '#' and insert the mention
        vim.api.nvim_buf_set_text(buf, row, col, row, after_hash, { mention })
        vim.api.nvim_win_set_cursor(state.input_win, { row + 1, col + #mention })
        vim.cmd("startinsert")
      end)

      return true
    end,
  })
end

--- Open the chat interface. Idempotent — safe to call multiple times.
function M.open()
  ensure_deps()
  if not state.cwd then state.cwd = vim.fn.getcwd() end

  -- Create or reuse output buffer
  if not state.chat_buf or not vim.api.nvim_buf_is_valid(state.chat_buf:bufnr()) then
    state.chat_buf = ChatBuffer:new("nexus://chat")
  end

  -- Open output (reuses window if already visible)
  state.chat_buf:open("right")

  -- Create or reuse render state
  if not state.render then
    state.render = renderer_mod.new(state.chat_buf:bufnr(), state.chat_buf:winnr())
    state.render:setup_keymaps(state.chat_buf:bufnr())
  else
    state.render:set_winnr(state.chat_buf:winnr())
  end

  -- Create or reuse input buffer
  local input_buf = state.input_buf
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
    input_buf = find_buf_by_name("nexus://chat/input")
    if not input_buf then
      input_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(input_buf, "nexus://chat/input")
    end
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    state.input_buf = input_buf
    state._input_keymaps_set = false
  end

  -- Close stale float if it exists
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_win_close(state.input_win, true)
  end

  -- Open floating input anchored to the chat window
  local chat_winnr = state.chat_buf:winnr()
  local win_w = vim.api.nvim_win_get_width(chat_winnr)
  local win_h = vim.api.nvim_win_get_height(chat_winnr)
  local float_w = math.max(win_w - 4, 20)
  local float_h = 3
  local row = win_h - float_h - 2
  local col = 1

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "win",
    win = chat_winnr,
    width = float_w,
    height = float_h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = build_title(),
    title_pos = "left",
    zindex = 50,
  })
  state.input_win = input_win

  -- Float window options
  vim.wo[input_win].wrap = true
  vim.wo[input_win].linebreak = true
  vim.wo[input_win].cursorline = true
  vim.wo[input_win].winhighlight = "Normal:NexusChatInput,FloatBorder:NexusChatInputBorder,FloatTitle:NexusChatInputTitle"

  -- Setup keymaps (only once per buffer lifetime)
  if not state._input_keymaps_set then
    vim.keymap.set("n", "<CR>", function() M.send() end,
      { buffer = input_buf, desc = "Send message" })
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      vim.cmd("stopinsert")
      M.send()
    end, { buffer = input_buf, desc = "Send message" })
    vim.keymap.set("n", "q", function() M.close() end,
      { buffer = input_buf, desc = "Close chat" })
    vim.keymap.set("n", "<C-c>", function() M.stop() end,
      { buffer = input_buf, desc = "Stop generation" })
    vim.keymap.set({ "n", "i" }, "<C-m>", function()
      vim.cmd("stopinsert")
      M.pick_model()
    end, { buffer = input_buf, desc = "Pick model" })
    vim.keymap.set({ "n", "i" }, "<C-a>", function()
      vim.cmd("stopinsert")
      M.pick_agent()
    end, { buffer = input_buf, desc = "Pick agent" })
    vim.keymap.set("i", "@", function()
      pick_file_mention()
    end, { buffer = input_buf, desc = "Pick file mention" })
    vim.keymap.set("i", "#", function()
      pick_grep_mention()
    end, { buffer = input_buf, desc = "Pick grep mention" })
    state._input_keymaps_set = true
  end

  vim.cmd("startinsert")

  -- Only show welcome message if buffer is empty
  local line_count = vim.api.nvim_buf_line_count(state.chat_buf:bufnr())
  local first_line = vim.api.nvim_buf_get_lines(state.chat_buf:bufnr(), 0, 1, false)[1] or ""
  if line_count <= 1 and first_line == "" then
    state.chat_buf:_append_lines({
      "# Nexus Chat",
      "",
      "**CWD:** " .. (state.cwd or vim.fn.getcwd()),
      "",
      "**Keybindings:**",
      "  `<Enter>` — send message (normal mode)",
      "  `<C-s>`   — send message (any mode)",
      "  `<C-a>`   — switch agent",
      "  `<C-m>`   — switch model",
      "  `<C-c>`   — stop generation",
      "  `@`       — pick file to mention (by name)",
      "  `#`       — pick file to mention (by content/grep)",
      "  `<Tab>`   — toggle folds",
      "  `q`       — close chat",
      "",
      "---",
    })
  end
end

--- Tool-specific input formatters.
--- Each returns { lines: string[], highlights: { line: integer, hl: string }[] }.
local tool_formatters = {
  Edit = function(input)
    local lines = {}
    local highlights = {}
    lines[#lines + 1] = input.file_path or "(unknown file)"
    highlights[#highlights + 1] = { line = 0, hl = "Directory" }

    if input.old_string and input.new_string then
      local diff_text = vim.diff(input.old_string .. "\n", input.new_string .. "\n", {
        result_type = "unified",
        ctxlen = 2,
      })
      if diff_text and diff_text ~= "" then
        local diff_lines = vim.split(diff_text, "\n", { plain = true })
        -- Skip the --- / +++ header (first 2 lines)
        local start_i = 1
        for i, dl in ipairs(diff_lines) do
          if dl:sub(1, 2) == "@@" then
            start_i = i
            break
          end
        end
        for i = start_i, #diff_lines do
          local dl = diff_lines[i]
          if dl ~= "" or i < #diff_lines then
            local offset = #lines
            lines[#lines + 1] = dl
            if dl:sub(1, 1) == "+" then
              highlights[#highlights + 1] = { line = offset, hl = "DiffAdd" }
            elseif dl:sub(1, 1) == "-" then
              highlights[#highlights + 1] = { line = offset, hl = "DiffDelete" }
            elseif dl:sub(1, 2) == "@@" then
              highlights[#highlights + 1] = { line = offset, hl = "DiffChange" }
            end
          end
        end
      end
    end
    return { lines = lines, highlights = highlights }
  end,

  Write = function(input)
    local lines = {}
    local highlights = {}
    lines[#lines + 1] = input.file_path or "(unknown file)"
    highlights[#highlights + 1] = { line = 0, hl = "Directory" }
    if input.content then
      local preview = input.content:sub(1, 500)
      for _, l in ipairs(vim.split(preview, "\n", { plain = true })) do
        lines[#lines + 1] = l
      end
      if #input.content > 500 then
        lines[#lines + 1] = "... (truncated)"
      end
    end
    return { lines = lines, highlights = highlights }
  end,

  Read = function(input)
    local lines = {}
    local highlights = {}
    local path = input.file_path or "(unknown file)"
    if input.offset or input.limit then
      path = path .. string.format(" [%s:%s]",
        input.offset and tostring(input.offset) or "1",
        input.limit and tostring(input.limit) or "end")
    end
    lines[#lines + 1] = path
    highlights[#highlights + 1] = { line = 0, hl = "Directory" }
    return { lines = lines, highlights = highlights }
  end,

  Bash = function(input)
    local lines = {}
    local highlights = {}
    if input.description then
      lines[#lines + 1] = "# " .. input.description
      highlights[#highlights + 1] = { line = 0, hl = "Comment" }
    end
    if input.command then
      lines[#lines + 1] = "$ " .. input.command
      highlights[#highlights + 1] = { line = #lines - 1, hl = "String" }
    end
    return { lines = lines, highlights = highlights }
  end,

  Glob = function(input)
    local lines = {}
    local highlights = {}
    lines[#lines + 1] = input.pattern or ""
    highlights[#highlights + 1] = { line = 0, hl = "String" }
    if input.path then
      lines[#lines + 1] = "in: " .. input.path
      highlights[#highlights + 1] = { line = 1, hl = "Directory" }
    end
    return { lines = lines, highlights = highlights }
  end,

  Grep = function(input)
    local lines = {}
    local highlights = {}
    lines[#lines + 1] = "/" .. (input.pattern or "") .. "/"
    highlights[#highlights + 1] = { line = 0, hl = "String" }
    if input.path then
      lines[#lines + 1] = "in: " .. input.path
      highlights[#highlights + 1] = { line = 1, hl = "Directory" }
    end
    return { lines = lines, highlights = highlights }
  end,
}

--- Default formatter for unrecognized tools.
---@param input table
---@return { lines: string[], highlights: table[] }
local function format_tool_default(input)
  local preview = vim.inspect(input):sub(1, 400)
  return {
    lines = vim.split(preview, "\n", { plain = true }),
    highlights = {},
  }
end

--- Format a tool_use block's input for display.
---@param name string Tool name
---@param input table Tool input
---@return { lines: string[], highlights: table[] }
local function format_tool_input(name, input)
  local formatter = tool_formatters[name]
  if formatter then
    return formatter(input)
  end
  return format_tool_default(input)
end

--- Send the current input as a message
function M.send()
  ensure_deps()
  if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
    vim.notify("Chat not open. Use :NexusChat to open.", vim.log.levels.WARN)
    return
  end

  -- Get input text
  local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
  local prompt = vim.trim(table.concat(lines, "\n"))
  if prompt == "" then
    vim.notify("Empty message", vim.log.levels.WARN)
    return
  end

  -- Clear input
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

  -- Show user message header
  state.chat_buf:user_header(prompt)
  state.chat_buf:assistant_header()

  -- Create fresh streaming parser
  state.parser = xml_parser.new()

  -- Update render state window reference
  if state.render then
    state.render:set_winnr(state.chat_buf:winnr())
  end

  -- Ensure agent exists (always use current model + agent def)
  if not state.agent then
    state.agent = build_agent(state.agent_def, state.model)
  end

  -- Track native content blocks by their index -> tag mapping
  -- The BlockRegistry maps native types (e.g. "thinking") to tag names
  local native_blocks = {}  -- index -> tag name
  local registry = require("nexus-agent.core.block_registry").get_instance()

  -- Record the user message
  table.insert(state.messages, {
    type = "user",
    content = prompt,
    timestamp = os.time(),
  })

  -- Run the agent (resume session if we have one for multi-turn context)
  local run_fn = function(p, callbacks)
    if state.session_id then
      return state.agent:resume(state.session_id, p, callbacks)
    else
      return state.agent:run(p, callbacks)
    end
  end

  state.session = run_fn(prompt, {
    on_message = function(msg)
      -- Store every parsed message for history/inspection
      msg.timestamp = msg.timestamp or os.time()
      table.insert(state.messages, msg)

      -- Capture session_id for multi-turn continuity
      if not state.session_id then
        if msg.type == "system" and msg.subtype == "init" and msg.session_id then
          state.session_id = msg.session_id
        elseif msg.type == "result" and msg.session_id then
          state.session_id = msg.session_id
        end
      end
    end,

    on_block_start = function(info)
      -- Check if this native content block type has a registered tag
      local tag = registry:tag_for_native(info.type)
      if tag and state.render then
        native_blocks[info.index] = tag
        -- Pass tool name/id so the renderer shows them in the header
        local attrs = {}
        if info.type == "tool_use" then
          attrs = { name = info.name, id = info.id }
        end
        state.render:process({
          { type = "tag_open", tag = tag, attrs = attrs },
        })
      end
    end,

    on_block_stop = function(index)
      local tag = native_blocks[index]
      if tag and state.render then
        native_blocks[index] = nil
        state.render:process({
          { type = "tag_close", tag = tag },
        })
      end
    end,

    on_thinking = function(text)
      -- Native thinking delta — feed directly to renderer as text
      -- The tag comes from the registry's native_type mapping
      local tag = registry:tag_for_native("thinking") or "thinking"
      if state.render then
        state.render:process({
          { type = "text", text = text, tag = tag },
        })
      end
    end,

    on_text = function(text)
      -- Regular text delta — feed through the streaming XML parser
      if state.parser and state.render then
        local events = state.parser:feed(text)
        state.render:process(events)
      end
    end,

    on_tool_use = function(tu)
      -- Full tool_use content block arrived — find matching renderer block
      -- and inject formatted content
      if not state.render or not tu.id then return end
      local blocks = state.render.blocks
      local block_idx
      for i, b in ipairs(blocks) do
        if b.attrs and b.attrs.id == tu.id then
          block_idx = i
          break
        end
      end
      if not block_idx then return end

      local formatted = format_tool_input(tu.name or "", tu.input or {})
      vim.schedule(function()
        state.render:inject_block_content(block_idx, formatted.lines, formatted.highlights)
      end)
    end,

    on_complete = function(result)
      -- Close any still-open native blocks
      if state.render then
        for index, tag in pairs(native_blocks) do
          state.render:process({
            { type = "tag_close", tag = tag },
          })
          native_blocks[index] = nil
        end
      end

      state.chat_buf:_append_lines({ "", "---" })
      if result and result.cost_usd then
        state.chat_buf:_append_lines({
          string.format("*Cost: $%.4f | Turns: %d | Duration: %dms*",
            result.cost_usd or 0, result.num_turns or 0, result.duration_ms or 0),
        })
      end

      state.parser = nil

      local status = require("nexus-agent.ui.status")
      status.get_instance():set_state("complete", {
        cost = result and result.cost_usd or 0,
      })
    end,

    on_error = function(err)
      state.chat_buf:_append_lines({ "", "**Error:** " .. tostring(err), "" })
      -- Clean up animation timers on error
      if state.render then
        state.render:destroy()
      end
    end,
  })
end

--- Stop the current generation
function M.stop()
  if state.session and state.session.stop then
    state.session:stop()
    state.chat_buf:_append_lines({ "", "*Stopped by user*", "" })
  end
  -- Clean up animation timers
  if state.render then
    for _, block in ipairs(state.render.blocks) do
      if block.timer then block.timer:close(); block.timer = nil end
    end
  end
end

--- Close the chat windows (buffers are kept alive for re-open).
function M.close()
  -- Close input float first (it's anchored to the chat window)
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_win_close(state.input_win, true)
  end
  state.input_win = nil
  -- Close chat window
  if state.chat_buf then state.chat_buf:close() end
end

--- Open the history picker showing all raw messages.
function M.history()
  local picker = require("nexus-chat.history_picker")
  picker.pick(state.messages)
end

--- Get the raw message history table.
---@return table[]
function M.get_messages()
  return state.messages
end

--- Clear the message history.
function M.clear_history()
  state.messages = {}
end

--- Start a fresh session (clears session_id so next send starts a new conversation).
function M.new_session()
  state.session_id = nil
  state.messages = {}
  state.cwd = vim.fn.getcwd()
  state.agent = build_agent(state.agent_def, state.model)
  if state.chat_buf and vim.api.nvim_buf_is_valid(state.chat_buf:bufnr()) then
    state.chat_buf:clear()
  end
  update_input_title()
  vim.notify("New chat session started", vim.log.levels.INFO)
end

--- Get the current session ID, if any.
---@return string?
function M.get_session_id()
  return state.session_id
end

--- Set the session ID (used by sessions picker to resume a CLI session).
---@param id string?
function M._set_session_id(id)
  state.session_id = id
end

--- Open the sessions browser (Telescope picker for Claude CLI sessions).
---@param opts? table
function M.sessions(opts)
  require("nexus-chat.sessions_picker").pick(opts)
end

--- Load a session's history into the chat buffer and set it as the active session.
--- Renders user messages, thinking blocks, tool calls, tool results, and text.
---@param session_info table Session table from sessions_picker (needs .path, .session_id/.id)
function M.load_session(session_info)
  ensure_deps()
  M.open()

  local scanner = require("nexus-chat.session_scanner")
  local sid = session_info.session_id or session_info.id

  -- Schedule everything after open() finishes its vim.schedule calls
  vim.schedule(function()
    -- Set session for multi-turn resume
    state.session_id = sid
    state.messages = {}

    -- Restore cwd from session if available
    if session_info.cwd then
      state.cwd = session_info.cwd
      state.agent = build_agent(state.agent_def, state.model)
      update_input_title()
    end

    -- Clear and reset buffer
    local bufnr = state.chat_buf:bufnr()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    vim.bo[bufnr].modifiable = false

    -- Reset render state
    if state.render then state.render:destroy() end
    state.render = renderer_mod.new(bufnr, state.chat_buf:winnr())
    state.render:setup_keymaps(bufnr)

    -- Read full conversation with block structure
    local conversation = scanner.read_session_blocks(session_info.path)

    -- Render each message synchronously using render_block
    local render = state.render
    for _, msg in ipairs(conversation) do
      if msg.role == "user" then
        render:append_lines({ "", "## > " .. (msg.content or ""):sub(1, 300):gsub("\n", " "), "" })
        render:append_lines({ "", "## Assistant", "" })

      elseif msg.role == "assistant" then
        for _, block in ipairs(msg.blocks or {}) do
          if block.type == "thinking" then
            render:render_block("thinking", block.content, {})

          elseif block.type == "text" then
            -- Feed through XML parser to extract <response>, <code>, etc.
            local parser = xml_parser.new()
            local events = parser:feed(block.content)
            local registry = require("nexus-agent.core.block_registry").get_instance()
            -- Collect text per-tag, then render as blocks
            local collecting_tag = nil
            local collected_text = ""
            for _, ev in ipairs(events) do
              if ev.type == "tag_open" and registry:is_registered(ev.tag) then
                -- Flush any plain text before this tag
                if collected_text ~= "" and not collecting_tag then
                  render:append_lines(vim.split(collected_text, "\n", { plain = true }))
                  collected_text = ""
                end
                collecting_tag = ev.tag
                collected_text = ""
              elseif ev.type == "text" then
                collected_text = collected_text .. (ev.text or "")
              elseif ev.type == "tag_close" then
                if collecting_tag then
                  render:render_block(collecting_tag, collected_text, {})
                  collecting_tag = nil
                  collected_text = ""
                end
              end
            end
            -- Flush remaining plain text
            if collected_text ~= "" then
              if collecting_tag then
                render:render_block(collecting_tag, collected_text, {})
              else
                render:append_lines(vim.split(collected_text, "\n", { plain = true }))
              end
            end

          elseif block.type == "tool_use" then
            local formatted = format_tool_input(block.name or "", block.input or {})
            local content = table.concat(formatted.lines, "\n")
            render:render_block("tool", content, { name = block.name })
          end
        end

      elseif msg.role == "tool_result" then
        local result_text = (msg.content or "")
        if #result_text > 1000 then
          result_text = result_text:sub(1, 1000) .. "\n... (truncated)"
        end
        render:render_block("result", result_text, {})
      end
    end

    -- Final separator
    render:append_lines({
      "", "---", "",
      "*Session loaded — " .. #conversation .. " messages. Type your follow-up.*",
    })

    -- Scroll to bottom
    local winnr = state.chat_buf:winnr()
    if winnr and vim.api.nvim_win_is_valid(winnr) then
      local count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(winnr, { count, 0 })
    end
  end)
end

--- Check if the chat is currently visible.
---@return boolean
function M.is_open()
  if not state.chat_buf then return false end
  local bufnr = state.chat_buf:bufnr()
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  return find_win_for_buf(bufnr) ~= nil
end

--- Toggle chat open/closed
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Focus the floating input, opening it if it was dismissed.
function M.focus_input()
  if not state.input_win or not vim.api.nvim_win_is_valid(state.input_win) then
    -- Float was dismissed — re-open (recreates the float and focuses it)
    M.open()
    return
  end
  vim.api.nvim_set_current_win(state.input_win)
  vim.cmd("startinsert")
end

return M
