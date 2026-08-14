defmodule OptimalSystemAgent.Tools.Builtins.TaskResume.Prompt do
  @moduledoc """
  Dynamic prompt for `task_resume`.

  References `task_stop` / `task_output` via `safe_ref/3` so the prompt stays
  accurate if either tool is ever renamed.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    task_stop_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskStop.Constants,
        :tool_name,
        "task_stop"
      )

    task_output_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskOutput.Constants,
        :tool_name,
        "task_output"
      )

    """
    Resume a paused, stopped, or backgrounded agent task by its agent id — a teammate
    cancelled with `#{task_stop_name}`, or a finished background run needing another pass. The
    prior task and a transcript tail are re-seeded; it runs in the background and reports
    on completion. No-op if it is still running; an unknown id returns a message, not an
    error. Use `#{task_output_name}` to inspect status first.
    """
  end

  # Lazy cross-tool name reference. Mirrors the pattern in `TaskStop.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
