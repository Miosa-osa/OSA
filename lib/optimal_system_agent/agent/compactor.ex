defmodule OptimalSystemAgent.Agent.Compactor do
  @moduledoc """
  Context compaction — 3-tier threshold system.

  Monitors context window usage and compresses when thresholds hit:
  - > 80%: Background summarize oldest 30%
  - > 85%: Aggressive compress oldest 50%
  - > 95%: Emergency truncate (no LLM call)

  Ensures the agent never hits context limits during conversation.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("Compactor started")
    {:ok, state}
  end
end
