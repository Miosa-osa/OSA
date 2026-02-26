defmodule OptimalSystemAgent.Intelligence.CommCoach do
  @moduledoc """
  Observes outbound messages and scores communication quality.
  Compares drafts against profiles to suggest improvements.

  Signal Theory — outbound message quality optimization.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}
end
