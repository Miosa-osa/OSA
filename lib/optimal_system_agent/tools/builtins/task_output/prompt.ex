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
    Get the output and status of a running or completed agent task.

    Use to check on background agents or retrieve their results. The response
    includes the agent's current status, iteration count, and token usage when
    the agent is still running.

    Related tools:
    - `#{task_write_name}` — inspect or update the agent's structured task list
    - `#{task_stop_name}` — cancel the agent if it is no longer needed

    If the agent has already completed or was never started, this tool returns
    a descriptive message rather than an error.
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
