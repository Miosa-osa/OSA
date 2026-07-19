defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Prompt do
  @moduledoc """
  Dynamic prompt for `task_wait`.

  References `delegate` / `task_output` via `safe_ref/3` so the prompt stays
  accurate if either tool is ever renamed.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    delegate_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.Delegate.Constants, :tool_name, "delegate")

    task_output_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskOutput.Constants,
        :tool_name,
        "task_output"
      )

    """
    Block until a chosen set of backgrounded agents finish, then return their results — a
    join-barrier for agents you launched with `#{delegate_name}(background: true)`.

    OSA already injects a <task-notification> automatically when each background agent
    completes — do NOT use `#{task_output_name}` or this tool just to check on a single agent
    you're waiting to hear back from; that notification will arrive on its own. Use
    `#{task_wait_name()}` ONLY when you need to actively CONVERGE on several already-launched
    agents before you can proceed (e.g. you dispatched 3 research agents earlier and now need
    all 3 done before synthesizing), instead of receiving their notifications one at a time and
    tracking completion yourself.

    Give the agentIds to wait on (from earlier delegate/background launches). By default waits
    for ALL of them (`require_all: true`); set it to `false` to return as soon as ANY one
    finishes. An optional `timeout_ms` bounds the wait (default 10 minutes) — on timeout, still-
    running agents are reported as such rather than erroring.

    Safety: nesting a blocking wait inside an agent that is ITSELF being waited on by another
    `#{task_wait_name()}` call is capped at a configured depth to prevent a chain of mutually-
    waiting agents from deadlocking or starving. A request that would exceed the ceiling is
    denied outright — prefer background dispatch + the automatic notification over deep nesting.
    """
  end

  defp task_wait_name do
    safe_ref(OptimalSystemAgent.Tools.Builtins.TaskWait.Constants, :tool_name, "task_wait")
  end

  # Lazy cross-tool name reference. Mirrors the pattern in `TaskResume.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
