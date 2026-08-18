defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors the pattern from `FileRead.Constants`. Other tools' prompts
  (e.g. `FileEdit.Prompt`) can reference `tool_name/0` via `safe_ref/3`
  so a rename propagates everywhere automatically.
  """

  @tool_name "file_write"
  def tool_name, do: @tool_name

  # Single shared policy — see `Agent.Safety.PathPolicy`.
  defdelegate blocked_write_paths,
    to: OptimalSystemAgent.Agent.Safety.PathPolicy,
    as: :blocked_write_patterns

  @soul_reload_files ~w(USER.md IDENTITY.md SOUL.md)
  def soul_reload_files, do: @soul_reload_files
end
