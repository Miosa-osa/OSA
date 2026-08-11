defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts reference `tool_name/0` so a rename here propagates
  everywhere automatically.
  """

  @tool_name "notebook_edit"
  def tool_name, do: @tool_name

  @actions ~w(read add_cell edit_cell delete_cell move_cell)
  def actions, do: @actions

  @default_allowed_paths ["~", "/tmp"]
  def default_allowed_paths, do: @default_allowed_paths

  # Single shared policy — see `Agent.Safety.PathPolicy`.
  defdelegate sensitive_paths,
    to: OptimalSystemAgent.Agent.Safety.PathPolicy,
    as: :sensitive_patterns

  defdelegate blocked_write_paths,
    to: OptimalSystemAgent.Agent.Safety.PathPolicy,
    as: :blocked_write_patterns

  # Maximum source size (bytes) for a single cell before the handler warns.
  @max_cell_bytes 512 * 1024
  def max_cell_bytes, do: @max_cell_bytes
end
