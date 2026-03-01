local M = {}

---@class nexus.InlineSession
---@field source_buf integer
---@field source_win integer
---@field filepath string
---@field filetype string
---@field cursor_line integer
---@field context_start integer
---@field context_end integer
---@field original_lines string[]
---@field input_buf integer?
---@field input_win integer?
---@field diff_buf integer?
---@field diff_win integer?
---@field replacement_lines string[]?
---@field handle table?

---@type nexus.InlineSession?
local session = nil

---@type nexus.Agent?
local agent = nil

--- Get or create the inline agent (lazy singleton).
---@return nexus.Agent
local function get_agent()
  if not agent then
    agent = require("nexus-inline.agent").create()
  end
  return agent
end

--- Close a floating window and delete its buffer.
---@param winnr integer?
---@param bufnr integer?
local function close_float(winnr, bufnr)
  if winnr and vim.api.nvim_win_is_valid(winnr) then
    vim.api.nvim_win_close(winnr, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

--- Open a small floating input window near the cursor.
---@param on_submit fun(instruction: string)
---@param on_cancel fun()
local function open_input_float(on_submit, on_cancel)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "text"

  local width = 60
  local height = 1
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Inline Edit ",
    title_pos = "center",
  })

  vim.cmd("startinsert")

  -- Submit: C-s
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local instruction = vim.trim(table.concat(lines, " "))
    if instruction == "" then
      on_cancel()
      return
    end
    on_submit(instruction)
  end, { buffer = buf })

  -- Cancel: Esc or q
  vim.keymap.set("n", "<Esc>", function() on_cancel() end, { buffer = buf })
  vim.keymap.set("n", "q", function() on_cancel() end, { buffer = buf })

  return buf, win
end

--- Build the prompt string from session context and user instruction.
---@param s nexus.InlineSession
---@param instruction string
---@return string
local function build_prompt(s, instruction)
  local parts = {
    "File: " .. s.filepath,
    "Filetype: " .. s.filetype,
    "Lines " .. s.context_start .. "-" .. s.context_end .. " (cursor at line " .. s.cursor_line .. "):",
    "",
  }
  for _, line in ipairs(s.original_lines) do
    table.insert(parts, line)
  end
  table.insert(parts, "")
  table.insert(parts, "Instruction: " .. instruction)
  return table.concat(parts, "\n")
end

--- Parse <replacement>...</replacement> from agent output.
---@param text string
---@return string[]?
local function parse_replacement(text)
  local content = text:match("<replacement>(.-)</replacement>")
  if not content then return nil end
  -- Strip leading/trailing newline from content
  content = content:gsub("^%s*\n", ""):gsub("\n%s*$", "")
  return vim.split(content, "\n", { plain = true })
end

--- Show the diff review floating window.
---@param s nexus.InlineSession
local function show_diff_review(s)
  local original_text = table.concat(s.original_lines, "\n") .. "\n"
  local replacement_text = table.concat(s.replacement_lines, "\n") .. "\n"

  local diff_text = vim.diff(original_text, replacement_text, {
    result_type = "unified",
    ctxlen = 3,
  })

  if not diff_text or diff_text == "" then
    vim.notify("No changes detected", vim.log.levels.INFO)
    session = nil
    return
  end

  local diff_lines = vim.split(diff_text, "\n", { plain = true })
  -- Remove trailing empty line from split
  if diff_lines[#diff_lines] == "" then
    table.remove(diff_lines)
  end

  -- Add footer
  table.insert(diff_lines, "")
  table.insert(diff_lines, " [a] Apply  [q/Esc] Reject")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "diff"

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#diff_lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Diff Review ",
    title_pos = "center",
  })

  -- Apply diff highlights via extmarks
  local ns = vim.api.nvim_create_namespace("nexus_inline_diff")
  for i, line in ipairs(diff_lines) do
    if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
      vim.api.nvim_buf_add_highlight(buf, ns, "DiffAdd", i - 1, 0, -1)
    elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      vim.api.nvim_buf_add_highlight(buf, ns, "DiffDelete", i - 1, 0, -1)
    elseif line:sub(1, 2) == "@@" then
      vim.api.nvim_buf_add_highlight(buf, ns, "DiffChange", i - 1, 0, -1)
    end
  end

  s.diff_buf = buf
  s.diff_win = win

  -- Keymaps
  vim.keymap.set("n", "a", function() M.apply() end, { buffer = buf })
  vim.keymap.set("n", "q", function() M.reject() end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() M.reject() end, { buffer = buf })
end

--- Called when the agent completes — parse replacement and show diff.
---@param accumulated_text string
local function on_agent_complete(accumulated_text)
  if not session then return end

  local replacement = parse_replacement(accumulated_text)
  if not replacement then
    vim.schedule(function()
      vim.notify("Failed to parse replacement from agent response", vim.log.levels.ERROR)
    end)
    session = nil
    return
  end

  session.replacement_lines = replacement

  vim.schedule(function()
    if not session then return end
    show_diff_review(session)
  end)
end

--- Open the inline edit prompt.
---@param opts? { line1?: integer, line2?: integer }
function M.open(opts)
  opts = opts or {}

  -- Cancel any active session
  if session then
    M.cancel()
  end

  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local filepath = vim.api.nvim_buf_get_name(source_buf)
  local filetype = vim.bo[source_buf].filetype
  local cursor = vim.api.nvim_win_get_cursor(source_win)
  local cursor_line = cursor[1]
  local line_count = vim.api.nvim_buf_line_count(source_buf)

  -- Determine context range
  local context_start, context_end
  if opts.line1 and opts.line2 then
    -- Visual selection range
    context_start = opts.line1
    context_end = opts.line2
  else
    -- Cursor +/- 10 lines
    context_start = math.max(1, cursor_line - 10)
    context_end = math.min(line_count, cursor_line + 10)
  end

  local original_lines = vim.api.nvim_buf_get_lines(source_buf, context_start - 1, context_end, false)

  session = {
    source_buf = source_buf,
    source_win = source_win,
    filepath = filepath ~= "" and filepath or "[unnamed]",
    filetype = filetype ~= "" and filetype or "text",
    cursor_line = cursor_line,
    context_start = context_start,
    context_end = context_end,
    original_lines = original_lines,
  }

  local input_buf, input_win = open_input_float(
    function(instruction)
      M.submit(instruction)
    end,
    function()
      M.cancel()
    end
  )

  session.input_buf = input_buf
  session.input_win = input_win
end

--- Submit the instruction to the agent.
---@param instruction string
function M.submit(instruction)
  if not session then return end

  -- Close input float
  close_float(session.input_win, session.input_buf)
  session.input_win = nil
  session.input_buf = nil

  -- Stop insert mode if active
  vim.cmd("stopinsert")

  local prompt = build_prompt(session, instruction)
  local accumulated = ""

  vim.notify("Inline edit running...", vim.log.levels.INFO)

  local a = get_agent()
  session.handle = a:run(prompt, {
    on_text = function(text)
      accumulated = accumulated .. text
    end,
    on_complete = function()
      on_agent_complete(accumulated)
    end,
    on_error = function(err)
      vim.schedule(function()
        vim.notify("Inline edit error: " .. err, vim.log.levels.ERROR)
      end)
      session = nil
    end,
  })
end

--- Apply the replacement to the source buffer.
function M.apply()
  if not session or not session.replacement_lines then return end

  -- Close diff float
  close_float(session.diff_win, session.diff_buf)

  -- Replace lines in source buffer
  vim.api.nvim_buf_set_lines(
    session.source_buf,
    session.context_start - 1,
    session.context_end,
    false,
    session.replacement_lines
  )

  -- Return focus to source window
  if vim.api.nvim_win_is_valid(session.source_win) then
    vim.api.nvim_set_current_win(session.source_win)
  end

  vim.notify("Inline edit applied", vim.log.levels.INFO)
  session = nil
end

--- Reject the replacement — close diff, no changes.
function M.reject()
  if not session then return end

  -- Close diff float
  close_float(session.diff_win, session.diff_buf)

  -- Return focus to source window
  if session.source_win and vim.api.nvim_win_is_valid(session.source_win) then
    vim.api.nvim_set_current_win(session.source_win)
  end

  session = nil
end

--- Cancel from the input stage.
function M.cancel()
  if not session then return end

  -- Stop agent if running
  if session.handle then
    session.handle:stop()
  end

  -- Close any open floats
  close_float(session.input_win, session.input_buf)
  close_float(session.diff_win, session.diff_buf)

  -- Stop insert mode if active
  vim.cmd("stopinsert")

  -- Return focus to source window
  if session.source_win and vim.api.nvim_win_is_valid(session.source_win) then
    vim.api.nvim_set_current_win(session.source_win)
  end

  session = nil
end

return M
