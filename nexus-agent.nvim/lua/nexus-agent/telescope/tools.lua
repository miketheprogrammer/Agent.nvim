--- Telescope picker for registered nexus-agent tools.
--- Lists all tools with schema preview and copy action.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

function M.tools(opts)
  opts = opts or {}

  local nexus = require("nexus-agent")
  local registry = nexus._tool_registry
  if not registry then
    vim.notify("No tool registry available", vim.log.levels.WARN)
    return
  end

  local tool_defs = registry:list_defs()
  if #tool_defs == 0 then
    vim.notify("No tools registered", vim.log.levels.INFO)
    return
  end

  table.sort(tool_defs, function(a, b)
    return a.name < b.name
  end)

  pickers.new(opts, {
    prompt_title = "Nexus Tools",
    finder = finders.new_table({
      results = tool_defs,
      entry_maker = function(tool)
        local display = string.format("%s  %s", tool.name, tool.description or "")
        return {
          value = tool,
          display = display,
          ordinal = tool.name .. " " .. (tool.description or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Tool Schema",
      define_preview = function(self, entry, status)
        local tool = entry.value
        local lines = {
          "# " .. tool.name,
          "",
          tool.description or "",
          "",
          "## Input Schema",
          "",
        }
        if tool.input_schema then
          local ok, encoded = pcall(vim.json.encode, tool.input_schema)
          if ok then
            -- Pretty-print JSON by splitting on newlines after vim.inspect-style formatting
            local formatted = vim.inspect(tool.input_schema)
            for line in formatted:gmatch("[^\n]+") do
              table.insert(lines, line)
            end
          else
            table.insert(lines, "(failed to encode schema)")
          end
        else
          table.insert(lines, "(no schema)")
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
          vim.fn.setreg("+", entry.value.name)
          vim.notify("Copied tool name: " .. entry.value.name, vim.log.levels.INFO)
        end
      end)
      map("i", "<C-t>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local tool = entry.value
          vim.ui.input({ prompt = "Test " .. tool.name .. " (JSON args): ", default = "{}" }, function(input)
            if not input then
              return
            end
            local ok, args = pcall(vim.json.decode, input)
            if not ok then
              vim.notify("Invalid JSON: " .. tostring(args), vim.log.levels.ERROR)
              return
            end
            local result = registry:execute(tool.name, args)
            local buf = vim.api.nvim_create_buf(true, true)
            local lines = { "# Tool Test: " .. tool.name, "", "## Input", input, "", "## Result", "" }
            if result.is_error then
              table.insert(lines, "[ERROR]")
            end
            if result.content then
              for _, block in ipairs(result.content) do
                if block.text then
                  for line in block.text:gmatch("[^\n]+") do
                    table.insert(lines, line)
                  end
                end
              end
            else
              table.insert(lines, vim.inspect(result))
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.bo[buf].filetype = "markdown"
            vim.bo[buf].bufhidden = "wipe"
            vim.api.nvim_set_current_buf(buf)
          end)
        end
      end)
      return true
    end,
  }):find()
end

return M
