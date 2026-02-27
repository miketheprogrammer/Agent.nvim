--- Session scanner for Claude CLI session files.
--- Uses ripgrep for fast parallel scanning of ~/.claude/projects/ JSONL files.

local M = {}

local claude_dir = vim.fn.expand("~") .. "/.claude/projects"
local uuid_pat = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x%.jsonl$"

--- Extract prompt text from a parsed user message entry.
---@param entry table Parsed JSONL object
---@return string
local function extract_prompt(entry)
  local msg = entry.message or entry
  local content = msg.content
  if type(content) == "string" then
    return content:sub(1, 200):gsub("\n", " ")
  end
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "string" then
        return block:sub(1, 200):gsub("\n", " ")
      end
      if type(block) == "table" then
        if block.type == "text" and block.text then
          return block.text:sub(1, 200):gsub("\n", " ")
        end
        -- Skip tool_result blocks — these are automated, not real prompts
        if block.type == "tool_result" then return "" end
      end
    end
  end
  return ""
end

--- Scan all Claude CLI session files using ripgrep.
--- One rg call scans every file in parallel — fast even with 800+ sessions.
---@param opts? { limit?: integer, project?: string }
---@return table[] sessions Newest first
function M.scan(opts)
  opts = opts or {}
  local limit = opts.limit or 100
  local search_dir = claude_dir
  if opts.project then
    search_dir = claude_dir .. "/" .. opts.project
  end

  -- Single rg invocation: find first "type":"user" line per file, output as JSON
  local raw = vim.fn.system({
    "rg", "--json", "-m1",
    '"type":"user"',
    search_dir,
    "-g", "*.jsonl",
  })

  local rg_lines = vim.split(raw, "\n", { trimempty = true })
  local sessions = {}

  for _, rg_line in ipairs(rg_lines) do
    local ok, rg_obj = pcall(vim.json.decode, rg_line)
    if not ok or rg_obj.type ~= "match" then goto next end

    local path = rg_obj.data.path.text
    local basename = vim.fn.fnamemodify(path, ":t")
    if not basename:match(uuid_pat) then goto next end

    local matched_text = rg_obj.data.lines.text
    local ok2, entry = pcall(vim.json.decode, matched_text)
    if not ok2 then goto next end

    local prompt = extract_prompt(entry)
    if prompt == "" then goto next end

    local parent = vim.fn.fnamemodify(path, ":h:t")
    sessions[#sessions + 1] = {
      path = path,
      project = parent,
      mtime = vim.fn.getftime(path),
      size = vim.fn.getfsize(path),
      id = basename:gsub("%.jsonl$", ""),
      session_id = entry.sessionId or basename:gsub("%.jsonl$", ""),
      slug = entry.slug,
      cwd = entry.cwd,
      branch = entry.gitBranch,
      prompt = prompt,
    }

    ::next::
  end

  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)

  if #sessions > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = sessions[i] end
    sessions = trimmed
  end

  return sessions
end

--- Read conversation from a single session file.
--- Only called on preview (one file at a time), so direct read is fine.
---@param path string
---@param opts? { max_lines?: integer }
---@return table[]
function M.read_conversation(path, opts)
  opts = opts or {}
  local max_lines = opts.max_lines or 500

  local ok, lines = pcall(vim.fn.readfile, path, "", max_lines)
  if not ok then return {} end

  local messages = {}
  for _, line in ipairs(lines) do
    if line == "" then goto continue end
    local ok2, obj = pcall(vim.json.decode, line)
    if not ok2 or type(obj) ~= "table" then goto continue end

    if obj.type == "user" then
      local prompt = extract_prompt(obj)
      if prompt ~= "" then
        messages[#messages + 1] = {
          role = "user",
          content = prompt,
          timestamp = obj.timestamp,
        }
      end

    elseif obj.type == "assistant" then
      local msg = obj.message or obj
      local parts = {}
      local tools = {}
      if type(msg.content) == "table" then
        for _, block in ipairs(msg.content) do
          if block.type == "text" and block.text and block.text ~= "" then
            parts[#parts + 1] = block.text
          elseif block.type == "thinking" and block.thinking then
            parts[#parts + 1] = "<thinking>" .. block.thinking:sub(1, 200) .. "</thinking>"
          elseif block.type == "tool_use" then
            tools[#tools + 1] = block.name or "?"
          end
        end
      end
      local content = table.concat(parts, "\n")
      if #tools > 0 then
        content = content .. "\n[tools: " .. table.concat(tools, ", ") .. "]"
      end
      if content ~= "" then
        messages[#messages + 1] = {
          role = "assistant",
          content = content,
          timestamp = obj.timestamp,
          model = msg.model,
        }
      end
    end

    ::continue::
  end
  return messages
end

--- Read a session's full block structure for history rendering.
--- Returns messages with preserved content blocks (thinking, text, tool_use).
---@param path string
---@param opts? { max_lines?: integer }
---@return table[] Array of { role, content?, blocks?: table[] }
function M.read_session_blocks(path, opts)
  opts = opts or {}
  local max_lines = opts.max_lines or 2000

  local ok, lines = pcall(vim.fn.readfile, path, "", max_lines)
  if not ok then return {} end

  local messages = {}
  for _, line in ipairs(lines) do
    if line == "" then goto continue end
    local ok2, obj = pcall(vim.json.decode, line)
    if not ok2 or type(obj) ~= "table" then goto continue end

    if obj.type == "user" then
      local msg = obj.message or obj
      local content = msg.content

      -- Check if this is a tool_result message (automated)
      if type(content) == "table" then
        local has_tool_result = false
        for _, block in ipairs(content) do
          if type(block) == "table" and block.type == "tool_result" then
            has_tool_result = true
            local result_content = ""
            if type(block.content) == "string" then
              result_content = block.content
            elseif type(block.content) == "table" then
              local parts = {}
              for _, r in ipairs(block.content) do
                if type(r) == "table" and r.text then parts[#parts + 1] = r.text
                elseif type(r) == "string" then parts[#parts + 1] = r end
              end
              result_content = table.concat(parts, "\n")
            end
            messages[#messages + 1] = {
              role = "tool_result",
              tool_use_id = block.tool_use_id,
              content = result_content,
            }
          end
        end
        if has_tool_result then goto continue end
      end

      -- Real user prompt
      local prompt = extract_prompt(obj)
      if prompt ~= "" then
        messages[#messages + 1] = { role = "user", content = prompt }
      end

    elseif obj.type == "assistant" then
      local msg = obj.message or obj
      local blocks = {}
      if type(msg.content) == "table" then
        for _, block in ipairs(msg.content) do
          if block.type == "thinking" and block.thinking then
            blocks[#blocks + 1] = { type = "thinking", content = block.thinking }
          elseif block.type == "text" and block.text and block.text ~= "" then
            blocks[#blocks + 1] = { type = "text", content = block.text }
          elseif block.type == "tool_use" then
            blocks[#blocks + 1] = {
              type = "tool_use",
              name = block.name or "?",
              input = block.input or {},
              id = block.id,
            }
          end
        end
      end
      if #blocks > 0 then
        messages[#messages + 1] = { role = "assistant", blocks = blocks }
      end
    end

    ::continue::
  end
  return messages
end

--- List project directories.
---@return string[]
function M.list_projects()
  local dirs = vim.fn.glob(claude_dir .. "/*", false, true)
  local projects = {}
  for _, d in ipairs(dirs) do
    if vim.fn.isdirectory(d) == 1 then
      projects[#projects + 1] = vim.fn.fnamemodify(d, ":t")
    end
  end
  table.sort(projects)
  return projects
end

return M
