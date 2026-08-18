defmodule OptimalSystemAgent.Tools.Builtins.DirList.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts (e.g. `FileRead.Prompt`) reference `tool_name/0` so a
  rename here propagates automatically across all prompt strings.
  """

  @tool_name "dir_list"
  def tool_name, do: @tool_name

  # Single shared policy — see `Agent.Safety.PathPolicy`. This accessor is a
  # description for prompts/tests; decisions go through `PathPolicy.sensitive?/1`.
  defdelegate sensitive_paths,
    to: OptimalSystemAgent.Agent.Safety.PathPolicy,
    as: :sensitive_patterns

  @max_suggestions 3
  def max_suggestions, do: @max_suggestions
end
