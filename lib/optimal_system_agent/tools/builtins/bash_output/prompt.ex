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
    with `run_in_background: true`, or moved there by outrunning its wait window.

    A completion notification may wake you instead, but only if something drives
    another turn of this session afterwards — true interactively, FALSE in a
    one-shot or headless run, which ends the moment you answer. So if you need
    the result, block on it here with `wait_ms` before answering; if you do not,
    leave it alone.
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
