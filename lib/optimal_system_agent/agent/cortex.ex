defmodule OptimalSystemAgent.Agent.Cortex do
  @moduledoc """
  Memory synthesis engine.

  Periodically synthesizes a "memory bulletin" from:
  - Recent conversations across all channels
  - Updated memory graph nodes
  - Pattern detection across contacts

  The bulletin is injected into the system prompt so the agent
  has ambient awareness of what's happening across all channels.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("Cortex started")
    {:ok, state}
  end
end
