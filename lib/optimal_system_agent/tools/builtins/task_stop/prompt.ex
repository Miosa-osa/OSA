defmodule OptimalSystemAgent.Tools.Builtins.TaskStop.Prompt do
  @moduledoc """
  Dynamic prompt for `task_stop`.

  References `task_write` via `safe_ref/3` so the prompt stays accurate
  if `task_write` is ever renamed.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    task_write_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskWrite.Constants,
        :tool_name,
        "task_write"
      )

    task_output_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskOutput.Constants,
        :tool_name,
        "task_output"
      )

    """
    Stop a running agent task by session ID.

    Use when a background agent is taking too long, is stuck, or is no longer
    needed. The cancellation is graceful — the agent's recorded task list (managed
    by `#{task_write_name}`) is preserved; no task data is permanently lost.

    To inspect an agent's status before stopping it, use `#{task_output_name}`.

    After calling this tool the agent will not produce further output. If the
    agent had already completed by the time this call is processed, the response
    will indicate that rather than returning an error.
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
