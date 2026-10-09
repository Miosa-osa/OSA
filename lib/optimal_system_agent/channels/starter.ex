defmodule OptimalSystemAgent.Channels.Starter do
  @moduledoc """
  Deferred channel startup using OTP-idiomatic handle_continue.

  Replaces the fragile `Task.start(fn -> Process.sleep(250); ... end)` pattern
  that was in Application.start/2. The GenServer initialises synchronously
  (guaranteeing it is placed in the supervision tree before any child triggers
  it), then immediately resumes with `{:continue, :start_channels}` which runs
  after `init/1` returns but before the next message is processed.

  This gives the rest of the supervision tree the chance to fully start (all
  processes registered, ETS tables created, etc.) before channels are started,
  without any wall-clock sleep.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, :ok, {:continue, :start_channels}}
  end

  @impl true
  def handle_continue(:start_channels, state) do
    # A headless run (`osa run`) is driven over stdin/stdout only; starting a
    # second poller for a channel a daemon already serves would steal its
    # traffic. Hooks are still registered below: they are run policy.
    if OptimalSystemAgent.RunProfile.headless?() do
      Logger.debug("Channels.Starter: headless run, no channel adapters")
    else
      Logger.info("Channels.Starter: starting configured channel adapters")
      OptimalSystemAgent.Channels.Manager.start_configured_channels()
    end

    # Auto-register HTTP and shell hooks from settings
    try do
      OptimalSystemAgent.Agent.Hooks.HttpHook.register_from_settings()
      OptimalSystemAgent.Agent.Hooks.ShellHook.register_from_settings()
      OptimalSystemAgent.Agent.Hooks.ApprovalHook.register_from_env()
      Logger.debug("Channels.Starter: hook registration from settings complete")
    rescue
      e -> Logger.debug("Channels.Starter: hook registration skipped: #{Exception.message(e)}")
    end

    {:noreply, state}
  end
end
