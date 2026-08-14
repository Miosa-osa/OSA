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
    Stop a running agent task by session ID — use when a background agent is stuck, too
    slow, or no longer needed. Cancellation is graceful: its `#{task_write_name}` task list is
    preserved. The agent produces no further output; if it had already completed, the
    response says so rather than erroring. Use `#{task_output_name}` to inspect status first.
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
