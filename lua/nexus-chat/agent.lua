local M = {}

--- Create the chat agent using nexus-agent public API
--- @param model? string Short model name ("sonnet", "opus", "haiku"). Default "sonnet".
--- @param cwd? string Working directory for the Claude subprocess.
--- @return table Agent instance
function M.create(model, cwd)
  model = model or "sonnet"
  local nexus = require("nexus-agent.api")

  local chat_agent = nexus
    .agent()
    :name("nexus-chat")
    :description("Interactive chat with XML-structured responses")
    :system_prompt(
      nexus
        .instructions()
        :role("You are a helpful coding assistant integrated into Neovim")
        :context("The user is working in Neovim and may ask about code, files, or projects")
        :rule("Be concise and direct in your responses")
        :rule("When showing code, always specify the language")
        :rule("When reasoning about your response, always use thinking tags")
        :format("Wrap your reasoning process in <thinking>...</thinking> tags")
        :format("Wrap your final response in <response>...</response> tags")
        :format("Wrap code snippets in <code lang='LANGUAGE'>...</code> tags")
        :format("Wrap shell commands in <shell>...</shell> tags")
        :build()
    )
    :model(model)
    :permission_mode("acceptEdits")
    :max_turns(25)

  if cwd then
    chat_agent:cwd(cwd)
  end

  chat_agent = chat_agent
    -- Block types are registered as defaults by the BlockRegistry.
    -- Custom agents can add their own blocks here, e.g.:
    -- :block({
    --   tag = "analysis",
    --   color = "#ff5faf",
    --   bg = "#2a1a2a",
    --   icon = "󰂖 ",
    --   active_label = "Analyzing",
    --   done_label = "Analysis",
    -- })
    :build()

  return chat_agent
end

return M
