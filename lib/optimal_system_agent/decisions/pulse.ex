defmodule OptimalSystemAgent.Decisions.Pulse do
  @moduledoc """
  Decision graph health reports — pulse checks for a team's reasoning state.

  `generate_pulse/1` inspects the decision graph for a given team and
  returns a structured health report covering:

    - **Total nodes** by type
    - **Stale decisions** — active decision nodes whose confidence has dropped
      below the stale threshold (default 0.4)
    - **Coverage gaps** — goal nodes that have no descendent decision nodes,
      meaning no one has made a concrete decision toward that goal
    - **Orphaned nodes** — nodes with no incoming or outgoing edges (except
      for goal nodes, which are expected to be roots)
    - **Pivot frequency** — number of revisit nodes (proxy for instability)
    - **Confidence distribution** — bucketed summary of all node confidence
      values so patterns of uncertainty are visible at a glance

  ## Output shape

      %{
        team_id:               string,
        generated_at:          string (ISO8601),
        total_nodes:           integer,
        by_type:               %{decision: N, option: N, goal: N, ...},
        stale_decisions:       [node_map, ...],
        coverage_gaps:         [goal_node_map, ...],
        orphaned_nodes:        [node_map, ...],
        pivot_count:           integer,
        confidence_buckets:    %{high: N, medium: N, low: N},
        health_score:          float   # 0.0 – 1.0
      }

  The `health_score` is a simple heuristic:
    1.0 − (stale_ratio * 0.4 + gap_ratio * 0.4 + orphan_ratio * 0.2)
  where each ratio is capped at 1.0.
  """

  require Logger

  alias OptimalSystemAgent.Decisions.Graph
  alias OptimalSystemAgent.Store.{Repo, DecisionNode}
  import Ecto.Query

  # Nodes whose confidence falls below this are considered stale
  @stale_threshold 0.4

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a health pulse report for the given team.

  Returns `{:ok, pulse_map}` or `{:error, reason}`.
  """
  @spec generate_pulse(String.t()) :: {:ok, map()} | {:error, term()}
  def generate_pulse(team_id) when is_binary(team_id) do
    case load_all_nodes(team_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, nodes} ->
        pulse = build_pulse(team_id, nodes)
        {:ok, pulse}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_all_nodes(team_id) do
    nodes =
      from(n in DecisionNode, where: n.team_id == ^team_id)
      |> Repo.all()
      |> Enum.map(&Graph.node_to_map/1)

    {:ok, nodes}
  rescue
    e ->
      Logger.warning(
        "[Decisions.Pulse] failed to load nodes for #{team_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  defp build_pulse(team_id, nodes) do
    total = length(nodes)
    by_type = count_by_type(nodes)

    stale_decisions = find_stale_decisions(nodes)
    coverage_gaps = find_coverage_gaps(nodes)
    orphaned_nodes = find_orphaned_nodes(nodes)
    pivot_count = Map.get(by_type, :revisit, 0)
    confidence_buckets = bucket_confidence(nodes)

    health_score =
      compute_health_score(
        total,
        length(stale_decisions),
        length(coverage_gaps),
        length(orphaned_nodes)
      )

    %{
      team_id: team_id,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      total_nodes: total,
      by_type: by_type,
      stale_decisions: stale_decisions,
      coverage_gaps: coverage_gaps,
      orphaned_nodes: orphaned_nodes,
      pivot_count: pivot_count,
      confidence_buckets: confidence_buckets,
      health_score: health_score
    }
  end

  defp count_by_type(nodes) do
    nodes
    |> Enum.group_by(& &1.type)
    |> Map.new(fn {type, group} -> {type, length(group)} end)
  end

  # Active decision nodes with confidence below the stale threshold
  defp find_stale_decisions(nodes) do
    Enum.filter(nodes, fn node ->
      node.type == :decision and
        node.status == :active and
        (node.confidence || 1.0) < @stale_threshold
    end)
  end

  # Goal nodes with no descendent decision nodes
  defp find_coverage_gaps(nodes) do
    goal_nodes = Enum.filter(nodes, &(&1.type == :goal))

    Enum.filter(goal_nodes, fn goal ->
      case Graph.descendants(goal.id, include_self: false, team_id: goal.team_id) do
        {:ok, descendants} ->
          not Enum.any?(descendants, &(&1.type == :decision))

        _ ->
          false
      end
    end)
  end

  # Nodes with zero edges in either direction (orphans)
  # Goal nodes are excluded since they are expected entry points
  defp find_orphaned_nodes(nodes) do
    non_goal_nodes = Enum.reject(nodes, &(&1.type == :goal))

    Enum.filter(non_goal_nodes, fn node ->
      outgoing = Graph.get_edges(node.id, direction: :out)
      incoming = Graph.get_edges(node.id, direction: :in)
      outgoing == [] and incoming == []
    end)
  end

  defp bucket_confidence(nodes) do
    Enum.reduce(nodes, %{high: 0, medium: 0, low: 0}, fn node, acc ->
      conf = node.confidence || 1.0

      cond do
        conf >= 0.7 -> Map.update!(acc, :high, &(&1 + 1))
        conf >= 0.4 -> Map.update!(acc, :medium, &(&1 + 1))
        true -> Map.update!(acc, :low, &(&1 + 1))
      end
    end)
  end

  defp compute_health_score(0, _stale, _gaps, _orphans), do: 1.0

  defp compute_health_score(total, stale, gaps, orphans) do
    stale_ratio = min(stale / total, 1.0)
    gap_ratio = min(gaps / max(total, 1), 1.0)
    orphan_ratio = min(orphans / total, 1.0)

    raw = 1.0 - (stale_ratio * 0.4 + gap_ratio * 0.4 + orphan_ratio * 0.2)
    Float.round(max(raw, 0.0), 3)
  end
end
