defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput.Prompt do
  @moduledoc """
  Dynamic prompt for `task_output`.

  References `task_write` and `task_stop` via `safe_ref/3` so the prompt
  stays accurate if those tools are ever renamed.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    task_write_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskWrite.Constants,
        :tool_name,
        "task_write"
      )

    task_stop_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskStop.Constants,
        :tool_name,
        "task_stop"
      )

    """
    Get the output and status of a running or completed agent task — status, iteration
    count, and token usage. An agent that already completed or never started yields a
    descriptive message, not an error.

    Related: `#{task_write_name}` (its task list), `#{task_stop_name}` (cancel it).
    """
  end

  # Lazy cross-tool name reference. Mirrors the pattern in `FileRead.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
