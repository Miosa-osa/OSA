defmodule OptimalSystemAgent.Tools.Builtins.StructuralEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "structural_edit"
  def tool_name, do: @tool_name

  # Single shared policy — see `Agent.Safety.PathPolicy`.
  defdelegate blocked_write_paths,
    to: OptimalSystemAgent.Agent.Safety.PathPolicy,
    as: :blocked_write_patterns
end
