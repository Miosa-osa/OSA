defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.Prompt do
  @moduledoc """
  Dynamic prompt for `bash_output`. References `shell_execute` via `safe_ref/3`
  so the prompt stays accurate if that tool is ever renamed.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    shell_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants,
        :tool_name,
        "shell_execute"
      )

    """
    Retrieve the cumulative stdout/stderr, status (running, done, failed,
    killed), and exit code of a background command started by `#{shell_name}`
    with `run_in_background: true`.

    DO NOT SPIN. A bare call returns instantly, so calling it in a loop while
    the command is `running`, or sleeping between calls, buys nothing and costs
    a round trip each time.

    To WAIT, pass `wait_ms` — ONE call that blocks until the command reaches a
    terminal status (`done`, `failed`, `killed`) or the wait elapses, then
    returns its final output. That is the only sanctioned way to wait, and it
    is the right move whenever your answer depends on the result: `wait_ms:
    600000` costs one tool call, not one per check.

    You may also be woken by a completion notification instead — but only if
    something drives another turn of this session after the command finishes.
    That happens in an interactive session and does NOT happen in a one-shot or
    headless run, which ends the moment you give your final answer. So: if you
    need the result, block on it here. If you do not need it, leave it alone.

    Use `kill: true` to stop a command early; it returns the final output too.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
