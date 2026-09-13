defmodule OptimalSystemAgent.Security.AttackPath do
  @moduledoc """
  Weighted shortest-path analytics over a ShadowGraph-shaped attack graph.

  ShadowGraph stores hosts/services/creds as a flat insight engine. This
  module is the pathfinder on top: Dijkstra from a principal to a high-value
  target, plus a simplified BloodHound JSON ingest so AD/cloud edges can live
  in the same structure.
  """

  @type graph :: %{
          nodes: map(),
          edges: [map()],
          processed_notes: MapSet.t()
        }

  @session_table :osa_attack_path_graphs

  @doc "Empty graph matching ShadowGraph.new/0."
  @spec new() :: graph()
  def new, do: %{nodes: %{}, edges: [], processed_notes: MapSet.new()}

  @doc "Stash a graph for a session (BloodHound ingest / path queries)."
  @spec store(String.t(), graph()) :: :ok
  def store(session_id, graph) when is_binary(session_id) and is_map(graph) do
    ensure_table()
    :ets.insert(@session_table, {session_id, graph})
    :ok
  end

  @doc "Fetch the session graph, or `new/0` if none."
  @spec fetch(String.t()) :: graph()
  def fetch(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@session_table, session_id) do
      [{^session_id, graph}] -> graph
      _ -> new()
    end
  end

  defp ensure_table do
    case :ets.whereis(@session_table) do
      :undefined -> :ets.new(@session_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  @doc """
  Weighted shortest path. Edge cost is `metadata.cost` (default 1.0).
  """
  @spec shortest_path(graph(), String.t(), String.t()) ::
          {:ok, %{nodes: [String.t()], edges: [map()], cost: number()}}
          | :unreachable
          | {:error, String.t()}
  def shortest_path(_graph, from, to) when from == to do
    {:ok, %{nodes: [from], edges: [], cost: 0.0}}
  end

  def shortest_path(%{nodes: nodes, edges: edges}, from, to)
      when is_binary(from) and is_binary(to) do
    cond do
      not Map.has_key?(nodes, from) ->
        {:error, "unknown node: #{from}"}

      not Map.has_key?(nodes, to) ->
        {:error, "unknown node: #{to}"}

      true ->
        dijkstra(nodes, edges, from, to)
    end
  end

  def shortest_path(_, _, _), do: {:error, "from and to must be node ids"}

  @doc "Paths from `from_id` to every reachable node, cheapest first."
  @spec paths_from(graph(), String.t(), keyword()) :: [map()]
  def paths_from(%{nodes: nodes} = graph, from_id, opts \\ []) do
    max_cost = Keyword.get(opts, :max_cost, 1.0e9)
    limit = Keyword.get(opts, :limit, 50)

    nodes
    |> Map.keys()
    |> Enum.reject(&(&1 == from_id))
    |> Enum.flat_map(fn to ->
      case shortest_path(graph, from_id, to) do
        {:ok, path} when path.cost <= max_cost -> [path]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.cost)
    |> Enum.take(limit)
  end

  @doc "Add an edge (and missing nodes). Returns a new graph."
  @spec add_edge(graph(), String.t(), String.t(), atom(), map()) :: graph()
  def add_edge(graph, source, target, type, metadata \\ %{}) do
    graph
    |> ensure_node(source)
    |> ensure_node(target)
    |> Map.update!(:edges, fn es ->
      es ++ [%{source: source, target: target, type: type, metadata: metadata}]
    end)
  end

  @doc "Ingest simplified BloodHound-style JSON (`nodes` + `edges`)."
  @spec ingest_bloodhound(graph(), String.t() | map()) :: {:ok, graph()} | {:error, String.t()}
  def ingest_bloodhound(graph, payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} -> ingest_bloodhound(graph, map)
      {:error, err} -> {:error, Exception.message(err)}
    end
  end

  def ingest_bloodhound(graph, %{"nodes" => nodes, "edges" => edges})
      when is_list(nodes) and is_list(edges) do
    g =
      Enum.reduce(nodes, graph, fn n, acc ->
        id = n["id"] || n["objectid"] || n["label"]

        if is_binary(id) do
          kind = n["kind"] || n["type"] || "host"
          put_node(acc, id, %{type: normalize_kind(kind), label: n["label"] || id})
        else
          acc
        end
      end)

    g =
      Enum.reduce(edges, g, fn e, acc ->
        src = e["source"] || e["start"]
        dst = e["target"] || e["end"]
        kind = e["kind"] || e["type"] || "RELATED"
        cost = e["cost"] || 1.0

        if is_binary(src) and is_binary(dst) do
          add_edge(acc, src, dst, edge_atom(kind), %{cost: cost, kind: kind})
        else
          acc
        end
      end)

    {:ok, g}
  end

  def ingest_bloodhound(_, _), do: {:error, "bloodhound payload needs nodes and edges arrays"}

  # ── Dijkstra ────────────────────────────────────────────────────────────

  defp dijkstra(nodes, edges, from, to) do
    adj = adjacency(edges)
    dist = %{from => 0.0}
    prev = %{}
    queue = :gb_sets.singleton({0.0, from})
    visited = MapSet.new()

    do_dijkstra(adj, Map.keys(nodes), to, dist, prev, queue, visited)
  end

  defp do_dijkstra(_adj, _ids, _to, _dist, _prev, {0, nil}, _visited), do: :unreachable

  defp do_dijkstra(adj, ids, to, dist, prev, queue, visited) do
    if :gb_sets.is_empty(queue) do
      :unreachable
    else
      {{cost, u}, queue} = :gb_sets.take_smallest(queue)

      cond do
        MapSet.member?(visited, u) ->
          do_dijkstra(adj, ids, to, dist, prev, queue, visited)

        u == to ->
          {:ok, reconstruct(prev, to, cost)}

        true ->
          visited = MapSet.put(visited, u)

          {dist, prev, queue} =
            Enum.reduce(Map.get(adj, u, []), {dist, prev, queue}, fn {v, w, edge}, {d, p, q} ->
              alt = cost + w

              if alt < Map.get(d, v, 1.0e18) do
                {Map.put(d, v, alt), Map.put(p, v, {u, edge}), :gb_sets.add({alt, v}, q)}
              else
                {d, p, q}
              end
            end)

          do_dijkstra(adj, ids, to, dist, prev, queue, visited)
      end
    end
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn e, acc ->
      w = edge_cost(e)
      Map.update(acc, e.source, [{e.target, w, e}], fn list -> [{e.target, w, e} | list] end)
    end)
  end

  defp edge_cost(%{metadata: %{cost: c}}) when is_number(c), do: c * 1.0
  defp edge_cost(%{metadata: %{"cost" => c}}) when is_number(c), do: c * 1.0
  defp edge_cost(_), do: 1.0

  defp reconstruct(prev, to, cost) do
    {nodes, edges} = walk_prev(prev, to, [to], [])
    %{nodes: nodes, edges: Enum.reverse(edges), cost: cost}
  end

  defp walk_prev(prev, node, nodes, edges) do
    case Map.get(prev, node) do
      nil -> {nodes, edges}
      {parent, edge} -> walk_prev(prev, parent, [parent | nodes], [edge | edges])
    end
  end

  defp ensure_node(graph, id) do
    if Map.has_key?(graph.nodes, id) do
      graph
    else
      type = id |> String.split(":", parts: 2) |> hd()
      put_node(graph, id, %{type: type})
    end
  end

  defp put_node(graph, id, attrs) do
    node = Map.merge(%{type: "host"}, attrs)
    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  defp normalize_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "user" -> "user"
      "computer" -> "computer"
      "group" -> "group"
      "gpo" -> "gpo"
      other -> other
    end
  end

  defp normalize_kind(_), do: "host"

  @edge_atoms %{
    "MemberOf" => :MemberOf,
    "AdminTo" => :AdminTo,
    "GenericAll" => :GenericAll,
    "WriteDacl" => :WriteDacl,
    "DCSync" => :DCSync,
    "CanRDP" => :CanRDP,
    "CanAssume" => :CanAssume,
    "HasPermission" => :HasPermission,
    "RELATED" => :RELATED,
    "HAS_SERVICE" => :HAS_SERVICE,
    "AUTH_ACCESS" => :AUTH_ACCESS,
    "CONNECTS_TO" => :CONNECTS_TO,
    "HAS_VULNERABILITY" => :HAS_VULNERABILITY,
    "HAS_FINDING" => :HAS_FINDING,
    "USES_TECHNOLOGY" => :USES_TECHNOLOGY,
    "CONTAINS" => :CONTAINS
  }

  defp edge_atom(kind) when is_binary(kind), do: Map.get(@edge_atoms, kind, :RELATED)

  defp edge_atom(kind) when is_atom(kind), do: kind
  defp edge_atom(_), do: :RELATED
end
