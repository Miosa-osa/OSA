defmodule OptimalSystemAgent.Decisions.Graph do
  @moduledoc """
  Core decision graph — SQLite-backed DAG with ETS cache layer.

  Models the full reasoning structure of an agent team as a directed acyclic
  graph. Nodes represent epistemic units (decisions, options, goals,
  observations, revisits). Edges represent the relationships between them.

  ## Storage

  Nodes and edges persist to SQLite via Ecto. Two ETS tables provide O(1)
  read access for hot paths:

    - `:osa_dg_nodes` — node_id → node map
    - `:osa_dg_edges` — {source_id, :out} / {target_id, :in} → [edge_map]

  ## Team Isolation

  Every query filters by `team_id`. Nodes from different teams are never
  mixed. Pass `team_id: nil` only for global/system-level graph operations.

  ## Node Types

    - `:decision`    — a committed choice made by an agent
    - `:option`      — a candidate considered but not yet chosen
    - `:goal`        — an objective the team is working toward
    - `:observation` — a factual note, evidence, or constraint
    - `:revisit`     — a flag that a prior decision needs re-evaluation

  ## Edge Types

    - `:leads_to`   — decision/option leads to another node
    - `:chosen`     — option was selected as the decision
    - `:rejected`   — option was ruled out
    - `:requires`   — node requires another node to be resolved first
    - `:blocks`     — node prevents progress on another
    - `:enables`    — node unlocks another
    - `:supersedes` — node replaces another (pivot chain)
    - `:supports`   — observation supports a decision/option
    - `:revises`    — revisit node points back to what it revises
    - `:summarizes` — node summarises a subtree
  """

  require Logger

  alias OptimalSystemAgent.Store.{Repo, DecisionNode, DecisionEdge}
  alias OptimalSystemAgent.Utils.ID
  import Ecto.Query

  @nodes_table :osa_dg_nodes
  @edges_table :osa_dg_edges

  # Maximum depth for traversal — prevents runaway queries on deep graphs
  @max_depth 50

  # ---------------------------------------------------------------------------
  # ETS bootstrap — called from Application.start/2 (or lazily on first use)
  # ---------------------------------------------------------------------------

  @doc "Create ETS tables for the decision graph cache. Safe to call multiple times."
  def init_tables do
    for table <- [@nodes_table, @edges_table] do
      try do
        :ets.new(table, [:named_table, :public, :set, {:read_concurrency, true}])
      rescue
        ArgumentError -> :already_exists
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Node CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Add a node to the graph.

  Required attrs: `:title`, `:type`, `:team_id`
  Optional attrs: `:description`, `:status`, `:confidence`, `:agent_name`,
                  `:session_id`, `:metadata`

  Returns `{:ok, node_map}` or `{:error, reason}`.
  """
  @spec add_node(map()) :: {:ok, map()} | {:error, term()}
  def add_node(attrs) do
    id = ID.generate("dg")

    params =
      attrs
      |> Map.put(:id, id)
      |> Map.put_new(:status, :active)
      |> Map.put_new(:confidence, 1.0)
      |> Map.put_new(:metadata, %{})

    case %DecisionNode{} |> DecisionNode.changeset(params) |> Repo.insert() do
      {:ok, node} ->
        node_map = node_to_map(node)
        cache_node(node_map)
        Logger.debug("[Decisions.Graph] node added #{id} (#{node.type})")
        {:ok, node_map}

      {:error, changeset} ->
        Logger.warning("[Decisions.Graph] add_node failed: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  @doc """
  Add a directed edge between two nodes.

  `source_id` and `target_id` must already exist.
  `type` is one of the 10 edge types (atom).
  `opts` accepts `:rationale` (string) and `:weight` (float, default 1.0).

  Returns `{:ok, edge_map}` or `{:error, reason}`.
  """
  @spec add_edge(String.t(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_edge(source_id, target_id, type, opts \\ []) do
    id = ID.generate("de")
    rationale = Keyword.get(opts, :rationale)
    weight = Keyword.get(opts, :weight, 1.0)

    params = %{
      id: id,
      source_id: source_id,
      target_id: target_id,
      type: type,
      rationale: rationale,
      weight: weight
    }

    case %DecisionEdge{} |> DecisionEdge.changeset(params) |> Repo.insert() do
      {:ok, edge} ->
        edge_map = edge_to_map(edge)
        cache_edge(edge_map)
        Logger.debug("[Decisions.Graph] edge added #{source_id} -[#{type}]-> #{target_id}")
        {:ok, edge_map}

      {:error, changeset} ->
        Logger.warning("[Decisions.Graph] add_edge failed: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  @doc """
  Update a node's fields. Only the provided fields are changed.

  Updatable fields: `:title`, `:description`, `:status`, `:confidence`,
                    `:agent_name`, `:metadata`

  Returns `{:ok, updated_map}` or `{:error, reason}`.
  """
  @spec update_node(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_node(node_id, attrs) do
    case fetch_node_record(node_id) do
      {:ok, record} ->
        case record |> DecisionNode.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            updated_map = node_to_map(updated)
            cache_node(updated_map)
            {:ok, updated_map}

          {:error, changeset} ->
            {:error, changeset.errors}
        end

      error ->
        error
    end
  end

  @doc """
  Fetch a node by ID. Checks ETS first, falls back to SQLite.

  Returns `{:ok, node_map}` or `{:error, :not_found}`.
  """
  @spec get_node(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_node(node_id) do
    case ets_lookup_node(node_id) do
      {:ok, _} = hit ->
        hit

      :miss ->
        case Repo.get(DecisionNode, node_id) do
          nil ->
            {:error, :not_found}

          record ->
            node_map = node_to_map(record)
            cache_node(node_map)
            {:ok, node_map}
        end
    end
  end

  @doc """
  Return all edges where `node_id` is either source or target.

  Pass `direction: :out` for outgoing only, `direction: :in` for incoming only.
  Default returns both directions.

  Returns a list of edge maps.
  """
  @spec get_edges(String.t(), keyword()) :: [map()]
  def get_edges(node_id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :both)
    load_edges_for_node(node_id, direction)
  end

  # ---------------------------------------------------------------------------
  # Graph traversal
  # ---------------------------------------------------------------------------

  @doc """
  Return all descendant node IDs reachable from `node_id` following outgoing
  edges. Includes the start node itself unless `opts[:include_self]` is false.

  Respects team isolation via `team_id`.

  Options:
    - `:team_id`      — filter traversal to a specific team (recommended)
    - `:include_self` — bool, default true
    - `:max_depth`    — integer, default #{@max_depth}

  Returns `{:ok, [node_map]}` or `{:error, reason}`.
  """
  @spec descendants(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def descendants(node_id, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    include_self = Keyword.get(opts, :include_self, true)
    team_id = Keyword.get(opts, :team_id)

    case do_traverse(node_id, :out, max_depth, team_id) do
      {:ok, ids} ->
        ids =
          if include_self,
            do: ids,
            else: List.delete(ids, node_id)

        nodes =
          ids
          |> Enum.flat_map(fn id ->
            case get_node(id) do
              {:ok, n} -> [n]
              _ -> []
            end
          end)
          |> maybe_filter_team(team_id)

        {:ok, nodes}

      error ->
        error
    end
  end

  @doc """
  Return all ancestor node IDs that can reach `node_id` by following edges
  upstream (i.e. traversing incoming edges in reverse).

  Options mirror `descendants/2`.

  Returns `{:ok, [node_map]}` or `{:error, reason}`.
  """
  @spec ancestors(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def ancestors(node_id, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    include_self = Keyword.get(opts, :include_self, true)
    team_id = Keyword.get(opts, :team_id)

    case do_traverse(node_id, :in, max_depth, team_id) do
      {:ok, ids} ->
        ids =
          if include_self,
            do: ids,
            else: List.delete(ids, node_id)

        nodes =
          ids
          |> Enum.flat_map(fn id ->
            case get_node(id) do
              {:ok, n} -> [n]
              _ -> []
            end
          end)
          |> maybe_filter_team(team_id)

        {:ok, nodes}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Traversal — BFS with visited set for cycle detection
  # ---------------------------------------------------------------------------

  defp do_traverse(start_id, direction, max_depth, _team_id) do
    do_bfs([start_id], MapSet.new([start_id]), direction, max_depth, 0)
  end

  defp do_bfs([], visited, _direction, _max_depth, _depth) do
    {:ok, MapSet.to_list(visited)}
  end

  defp do_bfs(_queue, visited, _direction, max_depth, depth)
       when depth >= max_depth do
    Logger.warning("[Decisions.Graph] traversal hit max depth #{max_depth} — stopping")
    {:ok, MapSet.to_list(visited)}
  end

  defp do_bfs(queue, visited, direction, max_depth, depth) do
    next_ids =
      queue
      |> Enum.flat_map(fn node_id ->
        edges = load_edges_for_node(node_id, direction)

        Enum.map(edges, fn edge ->
          if direction == :out, do: edge.target_id, else: edge.source_id
        end)
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_visited = Enum.reduce(next_ids, visited, &MapSet.put(&2, &1))
    do_bfs(next_ids, new_visited, direction, max_depth, depth + 1)
  end

  # ---------------------------------------------------------------------------
  # ETS helpers
  # ---------------------------------------------------------------------------

  defp ets_lookup_node(id) do
    try do
      case :ets.lookup(@nodes_table, id) do
        [{^id, node}] -> {:ok, node}
        [] -> :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  defp cache_node(node_map) do
    try do
      :ets.insert(@nodes_table, {node_map.id, node_map})
    rescue
      ArgumentError -> :ok
    end
  end

  defp cache_edge(edge_map) do
    try do
      out_key = {edge_map.source_id, :out}
      in_key = {edge_map.target_id, :in}

      for key <- [out_key, in_key] do
        existing =
          case :ets.lookup(@edges_table, key) do
            [{^key, list}] -> list
            [] -> []
          end

        unless Enum.any?(existing, &(&1.id == edge_map.id)) do
          :ets.insert(@edges_table, {key, [edge_map | existing]})
        end
      end
    rescue
      ArgumentError -> :ok
    end
  end

  defp load_edges_for_node(node_id, direction) do
    keys =
      case direction do
        :out -> [{node_id, :out}]
        :in -> [{node_id, :in}]
        :both -> [{node_id, :out}, {node_id, :in}]
      end

    cached =
      Enum.flat_map(keys, fn key ->
        try do
          case :ets.lookup(@edges_table, key) do
            [{^key, list}] -> list
            [] -> []
          end
        rescue
          ArgumentError -> []
        end
      end)

    if cached != [] do
      cached |> Enum.uniq_by(& &1.id)
    else
      load_edges_from_sqlite(node_id, direction)
    end
  end

  defp load_edges_from_sqlite(node_id, direction) do
    query =
      case direction do
        :out ->
          from(e in DecisionEdge, where: e.source_id == ^node_id)

        :in ->
          from(e in DecisionEdge, where: e.target_id == ^node_id)

        :both ->
          from(e in DecisionEdge,
            where: e.source_id == ^node_id or e.target_id == ^node_id
          )
      end

    query
    |> Repo.all()
    |> Enum.map(fn edge ->
      em = edge_to_map(edge)
      cache_edge(em)
      em
    end)
  rescue
    e ->
      Logger.warning("[Decisions.Graph] edge load error: #{Exception.message(e)}")
      []
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_node_record(node_id) do
    case Repo.get(DecisionNode, node_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp maybe_filter_team(nodes, nil), do: nodes

  defp maybe_filter_team(nodes, team_id) do
    Enum.filter(nodes, &(&1.team_id == team_id))
  end

  # ---------------------------------------------------------------------------
  # Struct → plain map conversions
  # ---------------------------------------------------------------------------

  @doc false
  def node_to_map(%DecisionNode{} = n) do
    %{
      id: n.id,
      type: safe_atom(n.type),
      title: n.title,
      description: n.description,
      status: safe_atom(n.status),
      confidence: n.confidence,
      agent_name: n.agent_name,
      team_id: n.team_id,
      session_id: n.session_id,
      metadata: n.metadata || %{},
      inserted_at: n.inserted_at,
      updated_at: n.updated_at
    }
  end

  @doc false
  def edge_to_map(%DecisionEdge{} = e) do
    %{
      id: e.id,
      source_id: e.source_id,
      target_id: e.target_id,
      type: safe_atom(e.type),
      rationale: e.rationale,
      weight: e.weight,
      inserted_at: e.inserted_at
    }
  end

  defp safe_atom(val) when is_atom(val), do: val
  defp safe_atom(val) when is_binary(val), do: String.to_existing_atom(val)
  defp safe_atom(_), do: nil
end
