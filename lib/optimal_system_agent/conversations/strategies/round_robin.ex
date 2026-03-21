defmodule OptimalSystemAgent.Conversations.Strategies.RoundRobin do
  @moduledoc """
  Round-robin turn strategy.

  Each participant speaks in order, cycling through the full list. The
  conversation ends after a configurable number of complete rounds (default 2).

  ## Strategy state

  Stored in `state.strategy_state`:

      %{rounds: pos_integer(), current_index: non_neg_integer()}

  `current_index` tracks position in the participants list. A full round
  completes when `current_index` wraps back to 0.
  """

  @behaviour OptimalSystemAgent.Conversations.TurnStrategy

  @default_rounds 2

  @impl true
  def next_speaker(%{participants: participants, strategy_state: ss}) do
    idx = Map.get(ss, :current_index, 0)
    participant = Enum.at(participants, rem(idx, max(length(participants), 1)))
    participant.name
  end

  @impl true
  def should_end?(%{
        turn_count: turn_count,
        max_turns: max_turns,
        participants: participants,
        strategy_state: ss
      }) do
    configured_rounds = Map.get(ss, :rounds, @default_rounds)
    participant_count = max(length(participants), 1)
    turns_for_rounds = configured_rounds * participant_count

    turn_count >= min(turns_for_rounds, max_turns)
  end

  @doc """
  Advance the internal index after a speaker has taken their turn.

  Called by `Conversations.Server` after appending a turn to the transcript.
  Returns the updated strategy_state map.
  """
  @spec advance(map()) :: map()
  def advance(%{participants: participants, strategy_state: ss} = _state) do
    idx = Map.get(ss, :current_index, 0)
    next_idx = rem(idx + 1, max(length(participants), 1))
    Map.put(ss, :current_index, next_idx)
  end

  @doc "Build initial strategy state from opts."
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      rounds: Keyword.get(opts, :rounds, @default_rounds),
      current_index: 0
    }
  end
end
