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
    Watch a target until it changes — file mtime, process exit, URL response, or
    command status. Returns when a change is observed or when the duration expires.

    Kinds:
    - `file`     — re-stat path; emit when mtime or size changes
    - `process`  — check pid liveness; emit on exit
    - `url`      — periodically GET; emit on status-code transition
    - `command`  — re-run shell command; emit on exit-code or output change

    The agent can call this concurrently with other tools — it doesn't block the
    main loop. Maximum duration is #{Constants.max_duration_seconds()}s; the
    poll interval defaults to #{Constants.default_poll_interval_ms()}ms.

    Prefer this over a `#{sleep_name}` + manual re-check when the trigger is
    external (file changes, process exit, HTTP transitions). Use `#{sleep_name}`
    for unconditional waits.
    """
  end
end
