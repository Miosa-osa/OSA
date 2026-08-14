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

    DO NOT USE THIS TOOL TO WAIT. Every background command notifies you
    automatically when it finishes, with its exit code and output path. Do not
    poll while `running`, do not `sleep` between calls, do not re-check for its
    artifact — do unrelated work, or stop and let the notification wake you. Use
    this to read output you were ALREADY notified about, or to stop a command
    early with `kill: true`.
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
