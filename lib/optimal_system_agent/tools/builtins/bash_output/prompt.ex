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
    Retrieve the output and status of a background shell command.

    Use this after starting a command with `#{shell_name}` and
    `run_in_background: true`, which returns a `background_id`. Call this tool
    with that id to retrieve the command's accumulated stdout/stderr (merged)
    so far, along with its current status (running, done, failed, or killed)
    and exit code once it has finished.

    Options:
    - `background_id` (required) — the id returned by `#{shell_name}`.
    - `kill` (optional) — when true, terminate the running command (SIGTERM,
      then SIGKILL) and return its final output/status.

    DO NOT USE THIS TOOL TO WAIT. Every background command notifies you
    automatically when it finishes, with its exit code and the path to its full
    output file — the notification re-enters your context by itself. So do not
    poll while status is `running`, do not `sleep` between calls, and do not
    re-check for the artifact the command produces. Doing so burns turns and
    wall-clock on information you are already going to be handed. Continue with
    unrelated work, or stop and let the notification wake you.

    Legitimate uses: reading the full output of a command you were ALREADY
    notified about, and stopping a command early with `kill: true`. Output is
    returned cumulatively from the start of the command each time.
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
