defmodule OptimalSystemAgent.Decisions.Narrative do
  @moduledoc """
  Timeline narrative generator for decision chains.

  Given a goal node, `build_narrative/1` walks the decision graph downstream
  and produces a structured, human-readable account of:

    - What decisions were made and by whom
    - What options were considered and why they were chosen or rejected
    - What pivots occurred and what triggered them
    - The confidence trajectory across the chain

  The output is a structured map (not raw prose) so callers can render it
  in any format — markdown, JSON API response, CLI display, etc.

  ## Output shape

      %{
        goal:      %{id, title, confidence},
        timeline:  [entry, ...],
        summary:   %{decisions: N, options: N, pivots: N, avg_confidence: float}
      }

  Each `entry` in `:timeline` has the shape:

      %{
        sequence:    integer,      # 1-based position
        node:        node_map,
        event_type:  atom,         # :decision_made | :option_considered | :pivot_occurred | :goal_set | :observation_noted
        note:        string | nil, # derived from incoming edge rationale
        edge_type:   atom | nil,   # type of the edge that led here
        confidence:  float
      }
  """

  require Logger

  alias OptimalSystemAgent.Decisions.Graph

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build a timeline narrative starting from a goal node.

  Walks all descendants of the goal, orders them by their insertion time,
  and classifies each node as a timeline event.

  Returns `{:ok, narrative_map}` or `{:error, reason}`.
  """
  @spec build_narrative(String.t()) :: {:ok, map()} | {:error, term()}
  def build_narrative(goal_node_id) when is_binary(goal_node_id) do
    case Graph.get_node(goal_node_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, goal_node} ->
        if goal_node.type != :goal do
          Logger.warning(
            "[Decisions.Narrative] node #{goal_node_id} is type #{goal_node.type}, expected :goal — building narrative anyway"
          )
        end

        case Graph.descendants(goal_node_id, include_self: false, team_id: goal_node.team_id) do
          {:error, reason} ->
            {:error, reason}

          {:ok, descendants} ->
            # Build edge lookup so we can annotate each node with how it was reached
            edge_index = build_edge_index(goal_node_id, descendants)

            timeline =
              descendants
              |> Enum.sort_by(fn node ->
                case node.inserted_at do
                  %NaiveDateTime{} = dt -> NaiveDateTime.to_string(dt)
                  %DateTime{} = dt -> DateTime.to_iso8601(dt)
                  str when is_binary(str) -> str
                  _ -> ""
                end
              end)
              |> Enum.with_index(1)
              |> Enum.map(fn {node, seq} ->
                incoming = Map.get(edge_index, node.id)
                build_entry(node, seq, incoming)
              end)

            summary = compute_summary(goal_node, timeline)

            {:ok,
             %{
               goal: %{
                 id: goal_node.id,
                 title: goal_node.title,
                 confidence: goal_node.confidence,
                 agent_name: goal_node.agent_name,
                 team_id: goal_node.team_id
               },
               timeline: timeline,
               summary: summary
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Build a map: node_id -> first incoming edge that brought it into scope
  defp build_edge_index(root_id, descendants) do
    all_ids = [root_id | Enum.map(descendants, & &1.id)]
    id_set = MapSet.new(all_ids)

    Enum.reduce(descendants, %{}, fn node, acc ->
      edges = Graph.get_edges(node.id, direction: :in)

      # Take the first edge whose source is within the subtree
      incoming =
        Enum.find(edges, fn e -> MapSet.member?(id_set, e.source_id) end)

      if incoming, do: Map.put(acc, node.id, incoming), else: acc
    end)
  end

  defp build_entry(node, seq, incoming_edge) do
    %{
      sequence: seq,
      node: node,
      event_type: classify_node(node, incoming_edge),
      note: note_from_edge(incoming_edge),
      edge_type: incoming_edge && incoming_edge.type,
      confidence: node.confidence
    }
  end

  defp classify_node(%{type: :decision}, %{type: :chosen}), do: :decision_made
  defp classify_node(%{type: :decision}, _), do: :decision_made
  defp classify_node(%{type: :option}, %{type: :rejected}), do: :option_rejected
  defp classify_node(%{type: :option}, _), do: :option_considered
  defp classify_node(%{type: :goal}, _), do: :goal_set
  defp classify_node(%{type: :revisit}, _), do: :pivot_occurred
  defp classify_node(%{type: :observation}, _), do: :observation_noted
  defp classify_node(_, _), do: :node_visited

  defp note_from_edge(nil), do: nil
  defp note_from_edge(%{rationale: nil}), do: nil
  defp note_from_edge(%{rationale: ""}), do: nil
  defp note_from_edge(%{rationale: rationale}), do: rationale

  defp compute_summary(goal_node, timeline) do
    counts =
      Enum.reduce(
        timeline,
        %{decisions: 0, options: 0, pivots: 0, observations: 0, total_confidence: 0.0},
        fn entry, acc ->
          acc
          |> increment_if(entry.event_type in [:decision_made], :decisions)
          |> increment_if(entry.event_type in [:option_considered, :option_rejected], :options)
          |> increment_if(entry.event_type == :pivot_occurred, :pivots)
          |> increment_if(entry.event_type == :observation_noted, :observations)
          |> Map.update!(:total_confidence, &(&1 + entry.confidence))
        end
      )

    total = length(timeline)

    avg_confidence =
      if total > 0,
        do: Float.round(counts.total_confidence / total, 3),
        else: goal_node.confidence

    %{
      decisions: counts.decisions,
      options: counts.options,
      pivots: counts.pivots,
      observations: counts.observations,
      total_nodes: total,
      avg_confidence: avg_confidence
    }
  end

  defp increment_if(map, true, key), do: Map.update!(map, key, &(&1 + 1))
  defp increment_if(map, false, _key), do: map
end
