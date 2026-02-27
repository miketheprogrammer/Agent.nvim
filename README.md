# Agent.nvim

Two lazy.nvim plugins for Claude Code CLI integration in Neovim:

- **nexus-agent** — AI agent SDK: spawn agents, stream responses, manage sessions, MCP, Telescope pickers
- **nexus-chat** — Interactive chat UI built on nexus-agent, with XML rendering, model/agent switching, and session history

## Requirements

- Neovim 0.10+
- [lazy.nvim](https://github.com/folke/lazy.nvim)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [Claude Code CLI](https://github.com/anthropics/claude-code) installed (default: `~/.local/bin/claude`)

## Installation

Both modules live in the same repo. Install once via nexus-agent; nexus-chat is configured as a virtual plugin (no separate clone needed).

```lua
-- nexus-agent installs the repo and sets up both modules
{
  "miketheprogrammer/agent.nvim",
  name = "nexus-agent",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  event = "VeryLazy",
  config = function()
    require("nexus-agent").setup({
      cli_path = vim.fn.expand("~") .. "/.local/bin/claude",
      model = "sonnet",
      cache_dir = vim.fn.expand("~") .. "/.cache/nvim/nexus-agent",
      permission_mode = "acceptEdits",
      debug = false,
    })
    require("nexus-chat").setup()
  end,
  keys = {
    { "<leader>n",  group = "[N]exus Agent" },
    { "<leader>na", function() require("nexus-agent").ask() end,        desc = "[N]exus [A]sk" },
    { "<leader>nc", function() require("nexus-chat").toggle() end,      desc = "[N]exus [C]hat" },
    { "<leader>nn", function() require("nexus-agent").new_agent() end,  desc = "[N]exus [N]ew Agent" },
    { "<leader>ns", function() require("nexus-agent").sessions() end,   desc = "[N]exus [S]essions" },
    { "<leader>nA", function() require("nexus-agent").agents() end,     desc = "[N]exus [A]gents" },
    { "<leader>nt", function() require("nexus-agent").tools() end,      desc = "[N]exus [T]ools" },
    { "<leader>nm", function() require("nexus-agent").activity() end,   desc = "[N]exus [M]essages" },
    { "<leader>nM", function() require("nexus-agent").mcp_status() end, desc = "[N]exus [M]CP" },
    { "<leader>ng", function() require("nexus-agent").changes() end,    desc = "[N]exus [G]it Changes" },
    { "<leader>nx", function() require("nexus-agent").stop() end,       desc = "[N]exus Stop" },
    { "<leader>nr", function() require("nexus-agent").resume() end,     desc = "[N]exus [R]esume" },
  },
},

-- nexus-chat: virtual plugin, no install — configured above via nexus-agent
{
  name = "nexus-chat",
  virtual = true,
  dependencies = { "nexus-agent" },
},
```

### Local development

```lua
{
  dir = "/path/to/Agent.nvim",
  name = "nexus-agent",
  -- same config as above
},
```

## Commands

### nexus-agent

| Command | Description |
|---|---|
| `:NexusAsk [prompt]` | Send a prompt to the default agent |
| `:NexusRun {agent} {prompt}` | Run a named agent |
| `:NexusNew` | Create a new agent definition |
| `:NexusEdit {agent}` | Edit an agent definition |
| `:NexusSessions` | Browse past sessions (Telescope) |
| `:NexusAgents` | Browse saved agents (Telescope) |
| `:NexusTools` | Browse registered tools (Telescope) |
| `:NexusActivity` | Live message feed (Telescope) |
| `:NexusMCP` | MCP server status (Telescope) |
| `:NexusChanges` | Git changes from the agent (Telescope) |
| `:NexusStop` | Stop the active agent |
| `:NexusResume [session_id]` | Resume a session |

### nexus-chat

| Command | Description |
|---|---|
| `:NexusChat` | Toggle the chat UI |
| `:NexusChatNew` | Start a fresh session |
| `:NexusChatHistory` | Browse message history (Telescope) |
| `:NexusChatSessions` | Browse Claude CLI sessions (Telescope) |
| `:NexusChatModel` | Switch model (Telescope) |
| `:NexusChatAgent` | Switch agent (Telescope) |

### Chat keybindings

#### Input float

| Key | Action |
|---|---|
| `<Enter>` | Send message (normal mode) |
| `<C-s>` | Send message (any mode) |
| `<C-a>` | Switch agent |
| `<C-m>` | Switch model |
| `<C-c>` | Stop generation |
| `q` | Close chat |

#### Message panel

| Key | Action |
|---|---|
| `a` | Focus input float (opens it if dismissed) |
| `<Tab>` | Toggle fold on current block |
| `]]` | Jump to next block |
| `[[` | Jump to previous block |

## Configuration

### nexus-agent options

```lua
require("nexus-agent").setup({
  cli_path        = "~/.local/bin/claude", -- Path to Claude Code CLI
  model           = "sonnet",              -- "sonnet" | "opus" | "haiku"
  cache_dir       = "~/.cache/nvim/nexus-agent",
  permission_mode = "acceptEdits",         -- "acceptEdits" | "bypassPermissions" | "default"
  system_prompt   = nil,                   -- Optional global system prompt
  allowed_tools   = nil,                   -- Optional tool allowlist
  mcp_servers     = nil,                   -- Optional MCP server config
  max_turns       = nil,                   -- Optional max turn limit
  debug           = false,                 -- Enable debug logging
})
```

## Lua API (nexus-agent)

```lua
local nexus = require("nexus-agent")

-- Programmatic query
nexus.ask("Explain this file", { model = "opus" })

-- Subscribe to events
nexus.on("message", function(msg) ... end)
nexus.on("tool_call", function(tool) ... end)
nexus.on("complete", function(result) ... end)

-- Builder pattern
local agent = nexus.agent()
  :name("my-agent")
  :model("sonnet")
  :system_prompt("You are a code reviewer.")
  :tool("Read")
  :build()

agent:run("Review this PR", { on_text = function(t) print(t) end })

-- Register a custom tool
nexus.register_tool({
  name = "my_tool",
  description = "Does something useful",
  input_schema = { ... },
  handler = function(input) return "result" end,
})
```
