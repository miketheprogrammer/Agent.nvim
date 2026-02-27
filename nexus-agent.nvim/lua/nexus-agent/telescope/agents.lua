--- Telescope picker for nexus-agent agent definitions.
--- Lists saved agents with preview and run/edit actions.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

function M.agents(opts)
  opts = opts or {}

  local agents_dir = vim.fn.expand("~") .. "/.cache/nvim/nexus-agent/agents"
  vim.fn.mkdir(agents_dir, "p")
  local agent_files = vim.fn.glob(agents_dir .. "/*.json", false, true)
  local agents = {}
  for _, file in ipairs(agent_files) do
    local content = table.concat(vim.fn.readfile(file), "\n")
    local ok, def = pcall(vim.json.decode, content)
    if ok then
      table.insert(agents, def)
    end
  end

  if #agents == 0 then
    vim.notify("No agents found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Nexus Agents",
    finder = finders.new_table({
      results = agents,
      entry_maker = function(agent)
        local display = string.format(
          "%s  [%s]  %s",
          agent.name,
          agent.model or "sonnet",
          agent.description or ""
        )
        return {
          value = agent,
          display = display,
          ordinal = agent.name .. " " .. (agent.description or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Agent Config",
      define_preview = function(self, entry, status)
        local agent = entry.value
        local lines = {
          "# " .. agent.name,
          "",
          "**Model:** " .. (agent.model or "sonnet"),
          "**Permission Mode:** " .. (agent.permission_mode or "default"),
          "**Max Turns:** " .. tostring(agent.max_turns or "unlimited"),
          "",
          "## System Prompt",
          agent.system_prompt or "(none)",
          "",
          "## Tools",
        }
        if agent.tools and #agent.tools > 0 then
          for _, tool in ipairs(agent.tools) do
            table.insert(lines, "- " .. tool)
          end
        else
          table.insert(lines, "(none)")
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          vim.ui.input({ prompt = "Prompt for " .. entry.value.name .. ": " }, function(input)
            if input then
              require("nexus-agent").run_agent(entry.value.name, input)
            end
          end)
        end
      end)
      map("i", "<C-e>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          require("nexus-agent.ui.agent_editor"):new():open(entry.value)
        end
      end)
      return true
    end,
  }):find()
end

return M
