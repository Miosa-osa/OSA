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

    Supervisor.init(children, strategy: :one_for_one)
  end
end
