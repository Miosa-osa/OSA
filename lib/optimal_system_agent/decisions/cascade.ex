defmodule OptimalSystemAgent.Decisions.Cascade do
  @moduledoc """
  Confidence propagation through the decision graph.

  When a node's confidence changes — because new evidence arrives, an agent
  revises its assessment, or a pivot demotes an old decision — confidence
  ripples downstream through outgoing edges. Edge weights control how much
  of the change propagates.

  ## Propagation formula

  For each downstream neighbour N reachable via an edge with weight W:

      new_confidence(N) = clamp(old_confidence(N) * (1 - W) + new_confidence(source) * W, 0.0, 1.0)

  A weight of 1.0 means the neighbour fully adopts the source's confidence.
  A weight of 0.0 means the neighbour is unaffected.

  ## Cycle detection

  A visited set is maintained across the propagation walk. A node is only
  updated once per call, even if reached via multiple paths.

  ## Side effects

  Each updated node fires a PubSub broadcast on `"osa:dg:team:<team_id>"` so
  live consumers (dashboards, other agents) see updates in real time.
  """

  require Logger

  alias OptimalSystemAgent.Decisions.Graph

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Propagate a confidence change from `node_id` to all downstream nodes.

  `new_confidence` must be in [0.0, 1.0].

  Returns `{:ok, updated_count}` where `updated_count` is the number of
  downstream nodes whose confidence was changed.
  """
  @spec propagate(String.t(), float()) :: {:ok, non_neg_integer()}
  def propagate(node_id, new_confidence)
      when is_binary(node_id) and is_float(new_confidence) and
             new_confidence >= 0.0 and new_confidence <= 1.0 do
    # Update the originating node first
    case Graph.update_node(node_id, %{confidence: new_confidence}) do
      {:ok, node} ->
        count = do_propagate([{node_id, new_confidence}], MapSet.new([node_id]), 0, node.team_id)
        {:ok, count}

      {:error, reason} ->
        Logger.warning(
          "[Decisions.Cascade] could not update origin node #{node_id}: #{inspect(reason)}"
        )

        {:ok, 0}
    end
  end

  def propagate(node_id, new_confidence) do
    Logger.warning(
      "[Decisions.Cascade] invalid confidence #{inspect(new_confidence)} for node #{node_id}"
    )

    {:ok, 0}
  end

  # ---------------------------------------------------------------------------
  # Private — BFS propagation
  # ---------------------------------------------------------------------------

  defp do_propagate([], _visited, count, _team_id), do: count

  defp do_propagate(queue, visited, count, team_id) do
    {next_queue, new_count} =
      Enum.flat_map_reduce(queue, 0, fn {source_id, source_confidence}, acc ->
        edges = Graph.get_edges(source_id, direction: :out)

        updates =
          edges
          |> Enum.flat_map(fn edge ->
            target_id = edge.target_id

            if MapSet.member?(visited, target_id) do
              []
            else
              case Graph.get_node(target_id) do
                {:ok, target} ->
                  weight = edge.weight || 1.0
                  blended = blend(target.confidence, source_confidence, weight)

                  if abs(blended - target.confidence) < 0.001 do
                    # Change too small to propagate further
                    []
                  else
                    case Graph.update_node(target_id, %{confidence: blended}) do
                      {:ok, updated} ->
                        broadcast_update(updated, team_id)
                        [{target_id, blended}]

                      _ ->
                        []
                    end
                  end

                _ ->
                  []
              end
            end
          end)

        {updates, acc + length(updates)}
      end)

    new_visited =
      Enum.reduce(next_queue, visited, fn {id, _}, acc -> MapSet.put(acc, id) end)

    do_propagate(next_queue, new_visited, count + new_count, team_id)
  end

  defp blend(old_confidence, source_confidence, weight) do
    raw = old_confidence * (1.0 - weight) + source_confidence * weight
    raw |> max(0.0) |> min(1.0)
  end

  defp broadcast_update(node, team_id) do
    topic = "osa:dg:team:#{team_id || "global"}"

    try do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        topic,
        {:confidence_updated, node}
      )
    rescue
      _ -> :ok
    end
  end
end
