defmodule OptimalSystemAgent.Supervisors.Sessions do
  @moduledoc """
  Subsystem supervisor for session and channel management processes.

  Manages channel adapters, the event stream registry, and the session
  DynamicSupervisor that owns individual agent Loop processes.

  Uses `:one_for_one` — a crashed channel adapter should not bring down
  the event stream registry or the session supervisor.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # cleanupPeriodDays (CC-parity): purge saved session transcripts older than
    # the retention window once at boot.
    #
    # Runs ASYNC. It `File.stat/2`s every file in the sessions directory, which
    # measured 178ms of boot here and grows with session history — and the
    # supervisor `init/1` callback is the worst possible place for it, since
    # nothing above this subsystem in the `:rest_for_one` root tree can start
    # until it returns. Nothing needs expired sessions to be gone before the
    # first keystroke is served, so it is dispatched onto the root
    # `TaskSupervisor` (started before this subsystem) and reaps in the
    # background. Best-effort: an unlinked task, so a failure cannot take the
    # supervisor with it.
    _ =
      Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
        OptimalSystemAgent.Agent.SessionPersistence.purge_expired()
      end)

    children = [
      # Channel adapters (CLI, HTTP, Telegram, Discord, Slack, etc.)
      {DynamicSupervisor,
       name: OptimalSystemAgent.Channels.Supervisor,
       strategy: :one_for_one,
       max_restarts: 5,
       max_seconds: 60},

      # Per-session event streams — must start before SessionSupervisor
      {Registry, keys: :unique, name: OptimalSystemAgent.EventStreamRegistry},

      # DynamicSupervisor for agent Loop processes
      # Must start before any code that creates sessions (CLI, HTTP, SDK)
      {DynamicSupervisor, name: OptimalSystemAgent.SessionSupervisor, strategy: :one_for_one}
    ]

    children
    |> OptimalSystemAgent.Supervisors.BootTiming.wrap("Sessions")
    |> Supervisor.init(strategy: :one_for_one)
  end
end
