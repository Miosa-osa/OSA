defmodule OptimalSystemAgent.Decisions.Merge do
  @moduledoc """
  Subtree merging — copy entire decision branches under new parents.

  Merging is useful when:
    - Two parallel workstreams converged and one team's decisions should
      become a sub-branch of the consolidated graph
    - A template decision tree is instantiated under a specific goal
    - A completed sub-graph from a prior session is imported into the
      current session's graph

  ## What gets copied

  A deep copy walk starting at `source_node_id`:
    1. All descendant nodes are discovered via `Graph.descendants/2`
    2. New IDs are generated for every copied node
    3. All edges *between* copied nodes are re-created with new IDs
       and the remapped source/target IDs
    4. A single new edge connects `target_parent_id` to the copied
       root node

  Edges that connect to nodes *outside* the subtree are not copied —
  the copy is self-contained.

  ## Options

    - `:supersede_source` — if `true`, marks the source subtree root
      as `:superseded` after the copy. Default: `false`.
    - `:prefix`           — prepend a string to all copied node titles.
      Useful for "Copy of …" labelling. Default: `nil`.
    - `:team_id`          — override the team_id on copied nodes.
      Defaults to the source node's team_id.
    - `:session_id`       — override the session_id on copied nodes.
  """

  require Logger

  alias OptimalSystemAgent.Decisions.Graph
  alias OptimalSystemAgent.Store.{Repo, DecisionNode, DecisionEdge}
  alias OptimalSystemAgent.Utils.ID
  import Ecto.Multi

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Deep-copy the subtree rooted at `source_node_id` and attach it under
  `target_parent_id` via a `:leads_to` edge.

  Returns `{:ok, %{root: node_map, nodes: [node_map], edges: [edge_map]}}` or
  `{:error, reason}`.
  """
  @spec merge_subtree(String.t(), String.t(), keyword()) ::
          {:ok, %{root: map(), nodes: [map()], edges: [edge_map :: map()]}}
          | {:error, term()}
  def merge_subtree(source_node_id, target_parent_id, opts \\ []) do
    supersede_source = Keyword.get(opts, :supersede_source, false)
    prefix = Keyword.get(opts, :prefix)
    team_id_override = Keyword.get(opts, :team_id)
    session_id_override = Keyword.get(opts, :session_id)

    with {:ok, source_node} <- Graph.get_node(source_node_id),
         {:ok, _target} <- Graph.get_node(target_parent_id),
         {:ok, subtree_nodes} <- Graph.descendants(source_node_id, include_self: true) do
      subtree_ids = MapSet.new(Enum.map(subtree_nodes, & &1.id))

      # Build a remapping table: old_id -> new_id
      id_map =
        Map.new(subtree_nodes, fn node ->
          {node.id, ID.generate("dg")}
        end)

      # Collect all internal edges (both endpoints within the subtree)
      internal_edges = collect_internal_edges(subtree_nodes, subtree_ids)

      team_id = team_id_override || source_node.team_id
      session_id = session_id_override || source_node.session_id

      # Build Multi
      multi = new()

      # Insert all copied nodes
      multi =
        Enum.reduce(subtree_nodes, multi, fn node, acc ->
          new_id = Map.fetch!(id_map, node.id)
          title = if prefix, do: "#{prefix} #{node.title}", else: node.title

          params = %{
            id: new_id,
            type: node.type,
            title: title,
            description: node.description,
            status: node.status,
            confidence: node.confidence,
            agent_name: node.agent_name,
            team_id: team_id,
            session_id: session_id,
            metadata: Map.put(node.metadata || %{}, "copied_from", node.id)
          }

          run(acc, {:node, node.id}, fn _repo, _changes ->
            %DecisionNode{} |> DecisionNode.changeset(params) |> Repo.insert()
          end)
        end)

      # Re-create internal edges with remapped IDs
      multi =
        Enum.reduce(internal_edges, multi, fn edge, acc ->
          new_id = ID.generate("de")
          new_source = Map.fetch!(id_map, edge.source_id)
          new_target = Map.fetch!(id_map, edge.target_id)

          params = %{
            id: new_id,
            source_id: new_source,
            target_id: new_target,
            type: edge.type,
            rationale: edge.rationale,
            weight: edge.weight
          }

          run(acc, {:edge, edge.id}, fn _repo, _changes ->
            %DecisionEdge{} |> DecisionEdge.changeset(params) |> Repo.insert()
          end)
        end)

      # Attach the new root under the target parent
      attach_edge_id = ID.generate("de")
      new_root_id = Map.fetch!(id_map, source_node_id)

      multi =
        run(multi, :attach_edge, fn _repo, _changes ->
          %DecisionEdge{}
          |> DecisionEdge.changeset(%{
            id: attach_edge_id,
            source_id: target_parent_id,
            target_id: new_root_id,
            type: :leads_to,
            rationale: "Subtree merged from #{source_node_id}",
            weight: 1.0
          })
          |> Repo.insert()
        end)

      case Repo.transaction(multi) do
        {:ok, changes} ->
          if supersede_source do
            Graph.update_node(source_node_id, %{status: :superseded})
          end

          copied_nodes =
            subtree_nodes
            |> Enum.map(fn node ->
              key = {:node, node.id}
              Graph.node_to_map(changes[key])
            end)

          copied_edges =
            internal_edges
            |> Enum.map(fn edge ->
              key = {:edge, edge.id}
              Graph.edge_to_map(changes[key])
            end)

          root_node = Graph.node_to_map(changes[{:node, source_node_id}])
          attach_edge = Graph.edge_to_map(changes.attach_edge)

          Logger.info(
            "[Decisions.Merge] merged #{length(copied_nodes)} nodes, #{length(copied_edges)} edges under #{target_parent_id}"
          )

          {:ok,
           %{
             root: root_node,
             nodes: copied_nodes,
             edges: [attach_edge | copied_edges]
           }}

        {:error, step, reason, _changes} ->
          Logger.warning("[Decisions.Merge] merge failed at #{Kernel.inspect(step)}: #{Kernel.inspect(reason)}")
          {:error, {step, reason}}
      end
    else
      {:error, :not_found} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp collect_internal_edges(nodes, subtree_ids) do
    nodes
    |> Enum.flat_map(fn node ->
      Graph.get_edges(node.id, direction: :out)
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(fn edge ->
      MapSet.member?(subtree_ids, edge.source_id) and
        MapSet.member?(subtree_ids, edge.target_id)
    end)
  end
end
