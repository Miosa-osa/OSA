defmodule OptimalSystemAgent.Conversations.Strategies.Weighted do
  @moduledoc """
  Relevance-weighted turn strategy.

  Participants with higher relevance scores speak more often. Initial weights
  are computed from role/perspective alignment to the conversation topic.
  After each turn, weights are adjusted based on contribution quality
  (measured by response length and keyword overlap with the topic).

  ## Weighting algorithm

  Initial weight:  `topic_alignment_score(persona, topic)` — keyword overlap
  Dynamic update:  after each turn, the speaker's weight is boosted proportional
                   to their contribution score, then all weights are normalised
                   to sum to 1.0.

  ## Speaker selection

  Uses weighted random sampling: given weights [0.5, 0.3, 0.2] for [A, B, C],
  participant A is selected 50% of the time, B 30%, C 20%.

  ## Strategy state

      %{
        weights:         %{participant_name => float()},
        contribution_log: [{participant_name, score, turn_count}]
      }
  """

  @behaviour OptimalSystemAgent.Conversations.TurnStrategy

  require Logger

  @min_weight 0.05
  @contribution_boost 0.15

  @impl true
  def next_speaker(%{participants: participants, strategy_state: ss}) do
    weights = Map.get(ss, :weights, %{})
    weighted_sample(participants, weights)
  end

  @impl true
  def should_end?(%{turn_count: turn_count, max_turns: max_turns}) do
    turn_count >= max_turns
  end

  @doc "Build initial strategy state. Weights are seeded from topic alignment."
  @spec init([map()], String.t(), keyword()) :: map()
  def init(participants, topic, _opts \\ []) do
    weights =
      participants
      |> Enum.map(fn p -> {p.name, initial_weight(p, topic)} end)
      |> Map.new()
      |> normalise()

    %{weights: weights, contribution_log: []}
  end

  @doc """
  Reweight after a turn.

  Returns updated strategy_state. Call from Conversations.Server after
  appending the turn to the transcript.
  """
  @spec reweight(map(), String.t(), String.t(), String.t()) :: map()
  def reweight(%{weights: weights, contribution_log: log} = ss, speaker, response, topic) do
    score = contribution_score(response, topic)

    boost = score * @contribution_boost
    current = Map.get(weights, speaker, 1.0 / max(map_size(weights), 1))
    updated_weights = Map.put(weights, speaker, current + boost)
    normalised = normalise(updated_weights)

    new_log = [{speaker, score, map_size(log)} | log] |> Enum.take(50)

    %{ss | weights: normalised, contribution_log: new_log}
  end

  @doc "Return current weights map for inspection."
  @spec weights(map()) :: %{String.t() => float()}
  def weights(%{weights: w}), do: w

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp weighted_sample([], _weights), do: "participant"

  defp weighted_sample(participants, weights) do
    total = participants |> Enum.map(&Map.get(weights, &1.name, @min_weight)) |> Enum.sum()
    r = :rand.uniform() * total

    {selected, _} =
      Enum.reduce_while(participants, {hd(participants), 0.0}, fn p, {_last, acc} ->
        w = Map.get(weights, p.name, @min_weight)
        new_acc = acc + w

        if new_acc >= r do
          {:halt, {p, new_acc}}
        else
          {:cont, {p, new_acc}}
        end
      end)

    selected.name
  end

  defp initial_weight(persona, topic) do
    topic_words = tokenise(topic)
    role_words = tokenise(persona.role <> " " <> persona.perspective)

    topic_set = MapSet.new(topic_words)
    role_set = MapSet.new(role_words)

    intersection = MapSet.intersection(topic_set, role_set) |> MapSet.size()
    union = MapSet.union(topic_set, role_set) |> MapSet.size()

    base = if union == 0, do: 0.5, else: intersection / union

    # Ensure minimum weight so no participant is ever silenced
    max(base, @min_weight)
  end

  defp contribution_score(response, topic) do
    topic_words = tokenise(topic) |> MapSet.new()
    response_words = tokenise(response) |> MapSet.new()

    overlap = MapSet.intersection(topic_words, response_words) |> MapSet.size()
    length_score = min(String.length(response) / 800.0, 1.0)
    keyword_score = if MapSet.size(topic_words) == 0, do: 0.5, else: overlap / MapSet.size(topic_words)

    # Combined: 60% keyword relevance, 40% substantive length
    keyword_score * 0.60 + length_score * 0.40
  end

  defp normalise(weights) when map_size(weights) == 0, do: weights

  defp normalise(weights) do
    total = weights |> Map.values() |> Enum.sum()

    if total == 0.0 do
      n = map_size(weights)
      Map.new(weights, fn {k, _} -> {k, 1.0 / n} end)
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end

  @stop_words ~w(a an the and or but in on at to for of is are was were be this that)

  defp tokenise(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp tokenise(_), do: []
end
