defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename here
  propagates automatically, following the pattern established by
  `FileRead.Constants`.
  """

  @tool_name "delegate"
  def tool_name, do: @tool_name

  @roles ~w(
    general-purpose explore plan code-review
    explorer planner architect backend frontend tester debugger
    security-auditor code-reviewer researcher devops doc-writer
    refactorer performance
  )
  def roles, do: @roles

  @tiers ~w(elite specialist utility)
  def tiers, do: @tiers

  # Subagent tier floor — utility models (3B-class) cannot reliably call tools.
  # Any :utility request is silently promoted to :specialist at dispatch time.
  @min_subagent_tier :specialist
  def min_subagent_tier, do: @min_subagent_tier
end
