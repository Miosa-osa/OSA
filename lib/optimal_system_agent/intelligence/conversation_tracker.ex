defmodule OptimalSystemAgent.Intelligence.ConversationTracker do
  @moduledoc """
  Tracks conversation depth per contact:
  casual → working → deep → strategic

  Adapts agent behavior based on depth — casual gets quick responses,
  strategic gets thorough analysis.

  Signal Theory — depth-adaptive conversation management.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}
end
