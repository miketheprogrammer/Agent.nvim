--- Telescope picker for registered MCP servers.
--- Shows server status, config preview, and management actions.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

function M.mcp_servers(opts)
  opts = opts or {}

  local nexus = require("nexus-agent")
  local mcp = nexus._mcp_client
  if not mcp then
    vim.notify("No MCP client available", vim.log.levels.WARN)
    return
  end

  local servers = mcp:list()
  if #servers == 0 then
    vim.notify("No MCP servers registered", vim.log.levels.INFO)
    return
  end

  table.sort(servers, function(a, b)
    return a.name < b.name
  end)

  pickers.new(opts, {
    prompt_title = "Nexus MCP Servers",
    finder = finders.new_table({
      results = servers,
      entry_maker = function(server)
        local cmd = server.config.command or ""
        local args_str = ""
        if server.config.args and #server.config.args > 0 then
          args_str = " " .. table.concat(server.config.args, " ")
        end
        local display = string.format(
          "%s  [%s]  %s%s",
          server.name,
          server.status or "stopped",
          cmd,
          args_str
        )
        return {
          value = server,
          display = display,
          ordinal = server.name .. " " .. cmd,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "MCP Server Config",
      define_preview = function(self, entry, status)
        local server = entry.value
        local cfg = server.config
        local lines = {
          "# " .. server.name,
          "",
          "**Status:** " .. (server.status or "stopped"),
          "**Command:** " .. (cfg.command or ""),
          "",
          "## Arguments",
        }
        if cfg.args and #cfg.args > 0 then
          for i, arg in ipairs(cfg.args) do
            table.insert(lines, string.format("  [%d] %s", i, arg))
          end
        else
          table.insert(lines, "  (none)")
        end
        table.insert(lines, "")
        table.insert(lines, "## Environment")
        if cfg.env and next(cfg.env) then
          for k, v in pairs(cfg.env) do
            table.insert(lines, string.format("  %s = %s", k, v))
          end
        else
          table.insert(lines, "  (none)")
        end
        if cfg.cwd then
          table.insert(lines, "")
          table.insert(lines, "## Working Directory")
          table.insert(lines, "  " .. cfg.cwd)
        end
        table.insert(lines, "")
        table.insert(lines, "## Available Tools")
        if cfg.tools and #cfg.tools > 0 then
          for _, tool in ipairs(cfg.tools) do
            table.insert(lines, "- " .. (type(tool) == "string" and tool or (tool.name or "?")))
          end
        else
          table.insert(lines, "  (tools discovered at runtime)")
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- Enter: show config details (copy JSON to clipboard)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local cfg = entry.value.config
          local ok, json = pcall(vim.json.encode, cfg)
          if ok then
            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(json, "\n"))
            vim.bo[buf].filetype = "json"
            vim.bo[buf].bufhidden = "wipe"
            vim.api.nvim_set_current_buf(buf)
          end
        end
      end)
      -- Ctrl-r: restart server
      map("i", "<C-r>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local name = entry.value.name
          if mcp.restart then
            mcp:restart(name)
            vim.notify("Restarting MCP server: " .. name, vim.log.levels.INFO)
          else
            vim.notify("MCP server restart not yet implemented", vim.log.levels.WARN)
          end
        end
      end)
      -- Ctrl-s: stop server
      map("i", "<C-s>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local name = entry.value.name
          if mcp.stop then
            mcp:stop(name)
            vim.notify("Stopping MCP server: " .. name, vim.log.levels.INFO)
          else
            vim.notify("MCP server stop not yet implemented", vim.log.levels.WARN)
          end
        end
      end)
      return true
    end,
  }):find()
end

return M
