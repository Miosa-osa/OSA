defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts
  reference `tool_name/0` so a rename here propagates everywhere
  automatically.
  """

  alias OptimalSystemAgent.Agent.Safety.PathPolicy

  @tool_name "file_edit"
  def tool_name, do: @tool_name

  # Files that must never be read from, and locations that must never be
  # written to. Both lists now come from `Agent.Safety.PathPolicy`, the single
  # shared policy — these accessors are descriptions for prompts and tests. Use
  # `PathPolicy.sensitive?/1` / `PathPolicy.blocked_write?/1` to make a
  # decision; substring-matching these strings is what the shared module exists
  # to stop.
  defdelegate sensitive_paths, to: PathPolicy, as: :sensitive_patterns
  defdelegate blocked_write_paths, to: PathPolicy, as: :blocked_write_patterns
end
