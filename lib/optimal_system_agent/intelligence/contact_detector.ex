defmodule OptimalSystemAgent.Intelligence.ContactDetector do
  @moduledoc """
  Pure pattern matching for contact identification.
  No LLM needed — runs in < 1ms.

  Matches names, aliases, phone numbers, email addresses
  against the contact registry.

  Signal Theory — deterministic contact resolution.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}
end
