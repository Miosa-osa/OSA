defmodule OptimalSystemAgent.Intelligence.CommProfiler do
  @moduledoc """
  Learns communication patterns per contact over time.
  Builds an incremental profile: preferred times, response patterns,
  topic preferences, formality level, communication style.

  Signal Theory — adaptive communication profiling.
  """
  use GenServer

  defstruct profiles: %{}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Get the communication profile for a user. Returns {:ok, profile} or {:ok, nil}."
  def get_profile(user_id) do
    GenServer.call(__MODULE__, {:get_profile, user_id})
  end

  @doc "Record a message from a user to update their profile."
  def record(user_id, message) do
    GenServer.cast(__MODULE__, {:record, user_id, message})
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:get_profile, user_id}, _from, state) do
    {:reply, {:ok, Map.get(state.profiles, user_id)}, state}
  end

  @impl true
  def handle_cast({:record, user_id, message}, state) do
    profile =
      Map.get(state.profiles, user_id, %{
        formality: 0.5,
        avg_length: 0,
        topics: [],
        message_count: 0
      })

    updated = update_profile(profile, message)
    {:noreply, %{state | profiles: Map.put(state.profiles, user_id, updated)}}
  end

  defp update_profile(profile, message) do
    count = profile.message_count + 1
    len = String.length(message)
    avg_len = (profile.avg_length * profile.message_count + len) / count
    formality = estimate_formality(message, profile.formality, count)

    %{profile | formality: formality, avg_length: round(avg_len), message_count: count}
  end

  defp estimate_formality(message, prev_formality, count) do
    lower = String.downcase(message)
    formal_markers = ~w(please kindly regarding therefore furthermore additionally)
    informal_markers = ~w(lol haha yeah nah gonna wanna kinda sorta yo sup bruh)

    formal_score = Enum.count(formal_markers, &String.contains?(lower, &1)) * 0.1
    informal_score = Enum.count(informal_markers, &String.contains?(lower, &1)) * 0.1

    new_score = 0.5 + formal_score - informal_score
    clamped = max(0.0, min(1.0, new_score))

    # Running average
    (prev_formality * (count - 1) + clamped) / count
  end
end
