local M = {}

--- Create the inline edit agent using nexus-agent public API.
--- Single-shot, no tools — outputs replacement code in <replacement> tags.
---@return nexus.Agent
function M.create()
  local nexus = require("nexus-agent.api")

  return nexus
    .agent()
    :name("nexus-inline")
    :description("Single-shot inline code editor")
    :model("sonnet")
    :max_turns(1)
    :permission_mode("bypass")
    :system_prompt(
      nexus
        .instructions()
        :role("You are a precise code editor. You receive a code snippet and an instruction, and output the modified code.")
        :context("The user is editing code in Neovim and wants a quick, targeted edit")
        :context("You will receive the file path, filetype, line range, and the code lines")
        :rule("Output ONLY the replacement code wrapped in <replacement>...</replacement> XML tags")
        :rule("Do NOT include any explanation, commentary, or text outside the tags")
        :rule("Preserve the original indentation style")
        :rule("Replace the ENTIRE provided code range — do not output partial replacements")
        :rule("If the instruction is unclear, make your best reasonable interpretation")
        :format("Wrap your output in <replacement>...</replacement> tags")
        :format("The content inside the tags should be valid code ready to replace the original range")
        :build()
    )
    :build()
end

return M
