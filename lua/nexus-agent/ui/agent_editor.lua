local AgentEditor = {}
AgentEditor.__index = AgentEditor

function AgentEditor:new()
  return setmetatable({
    _bufnr = nil,
    _winnr = nil,
    _agent_def = nil,
  }, self)
end

--- Open editor with an agent definition (or blank template)
--- @param agent_def table|nil
function AgentEditor:open(agent_def)
  agent_def = agent_def or {
    name = "",
    description = "",
    model = "sonnet",
    system_prompt = "",
    tools = {},
    permission_mode = "acceptEdits",
    max_turns = 10,
  }
  self._agent_def = agent_def

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "nexus://agent-editor/" .. (agent_def.name or "new"))
  vim.bo[buf].filetype = "yaml"  -- YAML-like format for readability
  vim.bo[buf].buftype = "acwrite"  -- triggers BufWriteCmd

  -- Generate template content
  local lines = self:_generate_template(agent_def)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Open in a new tab
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  self._bufnr = buf
  self._winnr = win

  -- Setup save command
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() self:save() end,
  })

  -- Keymap for save
  vim.keymap.set("n", "<leader>w", function() self:save() end, { buffer = buf, desc = "Save agent" })
end

--- Generate template lines from agent definition
function AgentEditor:_generate_template(def)
  return {
    "# Nexus Agent Definition",
    "# Edit and save (:w) to create/update the agent",
    "",
    "name: " .. (def.name or ""),
    "description: " .. (def.description or ""),
    "model: " .. (def.model or "sonnet"),
    "permission_mode: " .. (def.permission_mode or "acceptEdits"),
    "max_turns: " .. tostring(def.max_turns or 10),
    "",
    "# System prompt (everything below 'system_prompt:' until next section)",
    "system_prompt: |",
    "  " .. (def.system_prompt or "You are a helpful assistant."),
    "",
    "# Tools (one per line)",
    "tools:",
    "  - Read",
    "  - Write",
    "  - Bash",
    "  - Glob",
    "  - Grep",
  }
end

--- Parse buffer content back into agent definition
function AgentEditor:parse()
  if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then return nil end
  local lines = vim.api.nvim_buf_get_lines(self._bufnr, 0, -1, false)
  local def = {}
  local section = nil
  local prompt_lines = {}
  local tool_lines = {}

  for _, line in ipairs(lines) do
    if line:match("^#") then goto continue end  -- skip comments

    local key, val = line:match("^(%w+):%s*(.*)$")
    if key then
      if section == "system_prompt" then
        def.system_prompt = table.concat(prompt_lines, "\n")
        prompt_lines = {}
      elseif section == "tools" then
        def.tools = tool_lines
        tool_lines = {}
      end

      if key == "system_prompt" then
        section = "system_prompt"
      elseif key == "tools" then
        section = "tools"
      else
        section = nil
        if key == "max_turns" then
          def[key] = tonumber(val)
        else
          def[key] = val
        end
      end
    elseif section == "system_prompt" then
      table.insert(prompt_lines, line:match("^  (.*)$") or line)
    elseif section == "tools" then
      local tool = line:match("^%s*%-%s*(.+)$")
      if tool then table.insert(tool_lines, vim.trim(tool)) end
    end
    ::continue::
  end

  -- Capture last section
  if section == "system_prompt" then
    def.system_prompt = table.concat(prompt_lines, "\n")
  elseif section == "tools" then
    def.tools = tool_lines
  end

  return def
end

--- Save the agent definition
function AgentEditor:save()
  local def = self:parse()
  if not def or not def.name or def.name == "" then
    vim.notify("Agent must have a name", vim.log.levels.ERROR)
    return
  end

  -- Save to agents directory
  local agents_dir = vim.fn.expand("~") .. "/.cache/nvim/nexus-agent/agents"
  vim.fn.mkdir(agents_dir, "p")
  local path = agents_dir .. "/" .. def.name .. ".json"
  vim.fn.writefile({ vim.json.encode(def) }, path)
  vim.bo[self._bufnr].modified = false
  vim.notify("Agent saved: " .. def.name, vim.log.levels.INFO)
end

function AgentEditor:close()
  if self._winnr and vim.api.nvim_win_is_valid(self._winnr) then
    vim.api.nvim_win_close(self._winnr, true)
  end
end

return AgentEditor
