defmodule OptimalSystemAgent.Conversations.TurnStrategy do
  @moduledoc """
  Behaviour contract for conversation turn strategies.

  A turn strategy controls two decisions each turn:
    1. Who speaks next (next_speaker/1)
    2. Whether the conversation should end (should_end?/1)

  Implementations ship with the conversations system:
    - `Strategies.RoundRobin` — cycle through participants in order
    - `Strategies.Facilitator` — a designated agent steers the floor
    - `Strategies.Weighted`   — relevance-weighted speaker selection

  ## State shape

  Callbacks receive the full conversation server state map:

      %{
        type:         atom(),
        topic:        String.t(),
        participants: [Conversations.Persona.t()],
        transcript:   [{agent_id, message, DateTime.t()}],
        turn_count:   non_neg_integer(),
        status:       :running | :ended,
        max_turns:    pos_integer(),
        strategy_state: any()   # private strategy-owned slot
      }
  """

  @doc """
  Return the `name` (string id) of the agent who should speak next.

  The name must match the `:name` field of one of the `participants`.
  """
  @callback next_speaker(state :: map()) :: String.t()

  @doc """
  Return `true` when the conversation should be terminated.

  Called after every turn, before incrementing the turn counter.
  The strategy may inspect the full transcript to decide.
  """
  @callback should_end?(state :: map()) :: boolean()
end
