defmodule OptimalSystemAgent.Tools.Builtins.Monitor.Prompt do
  @moduledoc """
  Dynamic prompt for the `monitor` tool.

  Loosely mirrors upstream from the the upstream contract
  but adapted to OSA's existing capability surface (file watch, process
  status, URL ping, command exit code).
  """

  alias OptimalSystemAgent.Tools.Builtins.Monitor.Constants
  alias OptimalSystemAgent.Tools.Builtins.Sleep.Constants, as: SleepConst

  def render(_opts \\ []) do
    sleep_name =
      if Code.ensure_loaded?(SleepConst) and function_exported?(SleepConst, :tool_name, 0),
        do: SleepConst.tool_name(),
        else: "sleep"

    """
    Watch a target for changes — file mtime, process exit, URL response, or
    command status. Registers a background watcher and returns a `watch_id`
    IMMEDIATELY; it does NOT block your turn. You are notified automatically
    (the change is injected into the conversation) each time it fires.

    Kinds:
    - `file`     — re-stat path; notify when mtime or size changes
    - `process`  — check pid liveness; notify on exit
    - `url`      — periodically GET; notify on status-code transition
    - `command`  — re-run shell command; notify on exit-code or output change

    Modes:
    - `once`   (default) — notify on the first change, then retire
    - `repeat`           — keep watching and notify on EACH occurrence

    Optionally pass a `condition` to be told WHEN a state is reached rather than
    on any change (e.g. url `{"status": 200}`, command `{"exit": 0}`).

    Runs truly in the background — issue it and continue working; the watcher
    reports back on its own. Maximum duration is #{Constants.max_duration_seconds()}s;
    the poll interval defaults to #{Constants.default_poll_interval_ms()}ms.

    Prefer this over a `#{sleep_name}` + manual re-check when the trigger is
    external (file changes, process exit, HTTP transitions). Use `#{sleep_name}`
    for unconditional waits.
    """
  end
end
