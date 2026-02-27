local Folds = {}
Folds.__index = Folds

local ns_id = vim.api.nvim_create_namespace("nexus_folds")

function Folds:new(bufnr)
  return setmetatable({
    _bufnr = bufnr,
    _folds = {},  -- array of {id, start_line, end_line, title, collapsed}
    _ns_id = ns_id,
  }, self)
end

--- Create a collapsible fold region
--- @param start_line number 0-indexed
--- @param end_line number 0-indexed
--- @param title string Display text when folded (e.g., "Thinking")
--- @param collapsed boolean Whether to start collapsed
--- @return number fold_id
function Folds:create(start_line, end_line, title, collapsed)
  -- Use extmarks to mark the fold region
  -- Set fold markers
  local fold = {
    id = #self._folds + 1,
    start_line = start_line,
    end_line = end_line,
    title = title,
    collapsed = collapsed or false,
  }
  table.insert(self._folds, fold)

  -- Apply extmark for the fold header
  if collapsed then
    self:_collapse(fold)
  end

  return fold.id
end

--- Toggle fold at a given line
function Folds:toggle(line)
  for _, fold in ipairs(self._folds) do
    if line >= fold.start_line and line <= fold.end_line then
      fold.collapsed = not fold.collapsed
      if fold.collapsed then
        self:_collapse(fold)
      else
        self:_expand(fold)
      end
      return
    end
  end
end

--- Collapse a fold (hide content, show header with triangle)
function Folds:_collapse(fold)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    -- Use virtual text to show collapsed indicator
    vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_id, fold.start_line, 0, {
      id = fold.id * 1000,  -- unique extmark id
      virt_text = { { "▸ " .. fold.title .. " (collapsed)", "Comment" } },
      virt_text_pos = "overlay",
    })
    -- Hide the content lines using conceallevel or extmark end_line
  end)
end

--- Expand a fold (show content, header with triangle)
function Folds:_expand(fold)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    vim.api.nvim_buf_del_extmark(self._bufnr, self._ns_id, fold.id * 1000)
  end)
end

--- Setup fold keymaps for a buffer
function Folds:setup_keymaps()
  vim.keymap.set("n", "<Tab>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
    self:toggle(line)
  end, { buffer = self._bufnr, desc = "Toggle fold" })
end

--- Get all folds
function Folds:list() return self._folds end

return Folds
