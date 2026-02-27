--- Telescope picker for git changes during agent sessions.
--- Shows modified files with diff stats, preview, and open/diff/revert actions.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local M = {}

function M.git_changes(opts)
  opts = opts or {}
  local ref = opts.ref or "HEAD"
  local cwd = opts.cwd or vim.fn.getcwd()

  -- Get file status list
  local raw = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--name-status", ref })
  if vim.v.shell_error ~= 0 then
    vim.notify("git diff failed (not a git repo?)", vim.log.levels.WARN)
    return
  end

  -- Get numstat for +/- counts
  local numstat_raw = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--numstat", ref })
  local stats = {}
  for _, line in ipairs(numstat_raw) do
    local added, removed, file = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if file then
      stats[file] = { added = added or "0", removed = removed or "0" }
    end
  end

  local entries = {}
  for _, line in ipairs(raw) do
    local status, file = line:match("^(%S+)%s+(.+)$")
    if status and file then
      local st = stats[file]
      table.insert(entries, {
        status = status,
        file = file,
        added = st and st.added or "0",
        removed = st and st.removed or "0",
      })
    end
  end

  if #entries == 0 then
    vim.notify("No git changes found", vim.log.levels.INFO)
    return
  end

  pickers.new(opts, {
    prompt_title = "Git Changes",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        local display = string.format(
          "%s %s  (+%s -%s)",
          entry.status,
          entry.file,
          entry.added,
          entry.removed
        )
        return {
          value = entry,
          display = display,
          ordinal = entry.file,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Diff",
      define_preview = function(self, entry, status)
        local diff = vim.fn.systemlist({ "git", "-C", cwd, "diff", ref, "--", entry.value.file })
        if #diff == 0 then
          diff = { "(no diff available)" }
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, diff)
        vim.bo[self.state.bufnr].filetype = "diff"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- Enter: open file
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local filepath = cwd .. "/" .. entry.value.file
          if vim.fn.filereadable(filepath) == 1 then
            vim.cmd("edit " .. vim.fn.fnameescape(filepath))
          else
            vim.notify("File not found: " .. filepath, vim.log.levels.WARN)
          end
        end
      end)
      -- Ctrl-d: show full diff in buffer
      map("i", "<C-d>", function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local diff = vim.fn.systemlist({ "git", "-C", cwd, "diff", ref, "--", entry.value.file })
          local buf = vim.api.nvim_create_buf(true, true)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff)
          vim.bo[buf].filetype = "diff"
          vim.bo[buf].bufhidden = "wipe"
          vim.api.nvim_set_current_buf(buf)
        end
      end)
      -- Ctrl-r: revert changes for this file
      map("i", "<C-r>", function()
        local entry = action_state.get_selected_entry()
        if entry then
          local file = entry.value.file
          vim.ui.select({ "Yes", "No" }, {
            prompt = "Revert changes to " .. file .. "?",
          }, function(choice)
            if choice == "Yes" then
              vim.fn.systemlist({ "git", "-C", cwd, "checkout", ref, "--", file })
              if vim.v.shell_error == 0 then
                vim.notify("Reverted: " .. file, vim.log.levels.INFO)
              else
                vim.notify("Failed to revert: " .. file, vim.log.levels.ERROR)
              end
              actions.close(prompt_bufnr)
            end
          end)
        end
      end)
      return true
    end,
  }):find()
end

return M
