--- Telescope picker for nexus-agent sessions.
--- Lists all saved sessions with preview and resume/delete actions.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

function M.sessions(opts)
  opts = opts or {}

  local store = require("nexus-agent.session.store"):new()
  local sessions = store:list()

  if #sessions == 0 then
    vim.notify("No sessions found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Nexus Sessions",
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(session)
        local time_str = os.date("%Y-%m-%d %H:%M", session.timestamp)
        local model = session.model or "unknown"
        local prompt = (session.prompt or ""):sub(1, 50)
        local cost = session.total_cost_usd and string.format("$%.3f", session.total_cost_usd) or ""
        local turns = session.num_turns or 0
        local display = string.format("%s  [%s]  %s  (%s, %d turns)", time_str, model, prompt, cost, turns)
        return {
          value = session,
          display = display,
          ordinal = prompt .. " " .. (session.session_id or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Session Details",
      define_preview = function(self, entry, status)
        local session = entry.value
        local full = store:load(session.session_id) or session
        local lines = {
          "Session: " .. (full.session_id or ""),
          "Agent: " .. (full.agent or "default"),
          "Model: " .. (full.model or ""),
          "Time: " .. os.date("%Y-%m-%d %H:%M:%S", full.timestamp),
          "Turns: " .. tostring(full.num_turns or 0),
          "Cost: " .. (full.total_cost_usd and string.format("$%.4f", full.total_cost_usd) or "N/A"),
          "Duration: " .. tostring(full.duration_ms or 0) .. "ms",
          "",
          "--- Prompt ---",
          full.prompt or "",
          "",
          "--- Result ---",
          full.result or "(no result)",
        }
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          vim.ui.input({ prompt = "Follow-up: " }, function(input)
            if input then
              require("nexus-agent").resume(entry.value.session_id, input)
            end
          end)
        end
      end)
      map("i", "<C-d>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          store:delete(entry.value.session_id)
          vim.notify("Session deleted", vim.log.levels.INFO)
          actions.close(prompt_bufnr)
        end
      end)
      map("i", "<C-r>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local full = store:load(entry.value.session_id) or entry.value
          local result_text = full.result or "(no result)"
          local buf = vim.api.nvim_create_buf(true, true)
          local lines = vim.split(result_text, "\n")
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
