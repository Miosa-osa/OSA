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
    Resume a paused, stopped, or backgrounded agent task by its agent id.

    Use to continue a teammate that was cancelled with `#{task_stop_name}`, or a
    background/parallel run that finished but needs another pass. The prior run's
    task and a tail of its transcript are re-seeded so the resumed agent picks up
    with context. The resumed agent runs in the background and reports back on
    completion.

    To inspect an agent's status or stored result first, use `#{task_output_name}`.

    If the agent is still actively running, this is a no-op and the response says
    so. If no run is known for the id, the response indicates that rather than
    returning an error.
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
