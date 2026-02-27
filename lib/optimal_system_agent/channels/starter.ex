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
    Logger.info("Channels.Starter: starting configured channel adapters")
    OptimalSystemAgent.Channels.Manager.start_configured_channels()
    {:noreply, state}
  end
end
