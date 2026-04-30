defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation.Prompt do
  @moduledoc """
  Dynamic prompt for `spawn_conversation`.
  """

  alias OptimalSystemAgent.Conversations.Tools.SpawnConversation.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    types = Enum.join(Constants.valid_types(), ", ")
    roles = Enum.join(Constants.predefined_roles(), ", ")
    strategies = Enum.join(Constants.valid_strategies(), ", ")

    """
    Spawn a structured multi-agent conversation and receive its summary.

    Participants are AI personas that debate and discuss the topic. The
    conversation runs synchronously and returns key decisions, action items,
    dissenting views, and open questions.

    Conversation types: #{types}
    Predefined roles: #{roles}
    Turn strategies: #{strategies}

    - `participant_roles` accepts predefined keys or custom role strings
    - Minimum 2, maximum 8 participants
    - Default turn strategy: round_robin (default max_turns: #{Constants.default_max_turns()})
    """
  end
end
