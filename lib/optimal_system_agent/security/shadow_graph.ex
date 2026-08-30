defmodule OptimalSystemAgent.Security.ShadowGraph do
  @moduledoc """
  Attack surface knowledge graph — derives strategic insights from security notes.

  Builds a directed graph from
  structured notes: nodes are hosts, services, credentials, vulnerabilities,
  and findings. Edges are relationships (HAS_SERVICE, AUTH_ACCESS, CONNECTS_TO,
  HAS_VULNERABILITY, HAS_FINDING).

  The orchestrator queries the graph for strategic insights:
  - "We have creds for host X but haven't scanned it"
  - "Host X has a known vulnerability on service Y"
  - "Host X is connected to host Y"
  - "We found credentials on host X that give access to host Y"

  ## Graph structure

  Nodes:
    * `host:<ip>` — a discovered host
    * `service:<host>:<port>` — a service running on a host
    * `credential:<key>` — a credential note
    * `vulnerability:<key>` — a vulnerability note
    * `finding:<key>` — a finding note
    * `technology:<host>:<name>` — a technology on a host

  Edges:
    * `HAS_SERVICE` — host → service
    * `AUTH_ACCESS` — credential → host (creds can access this host)
    * `CONTAINS` — host → credential (creds found on this host)
    * `HAS_VULNERABILITY` — host → vulnerability
    * `HAS_FINDING` — host → finding
    * `USES_TECHNOLOGY` — host → technology
    * `CONNECTS_TO` — host → host (network connection discovered)

  ## Usage

      graph = ShadowGraph.new()
      graph = ShadowGraph.update_from_notes(graph, notes)
      insights = ShadowGraph.strategic_insights(graph)
  """

  require Logger

  alias OptimalSystemAgent.Security.StructuredNotes

  @type node_id :: String.t()
  @type graph :: %{
          nodes: %{node_id() => map()},
          edges: [edge()],
          processed_notes: MapSet.t()
        }

  @type edge :: %{
          source: node_id(),
          target: node_id(),
          type: atom(),
          metadata: map()
        }

  @doc "Create a new empty graph."
  @spec new() :: graph()
  def new, do: %{nodes: %{}, edges: [], processed_notes: MapSet.new()}

  @table :osa_security_shadow_graph

  @doc """
  Session-scoped graph view. Returns the stored graph for `session_id`, or an
  empty graph when nothing was stored yet.
  """
  @spec get_graph(String.t()) :: graph()
  def get_graph(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, graph}] -> graph
      [] -> new()
    end
  end

  @doc "Store a session's graph so path queries (roots, outgoing edges) can find it."
  @spec store_graph(String.t(), graph()) :: :ok
  def store_graph(session_id, graph) when is_binary(session_id) and is_map(graph) do
    ensure_table()
    :ets.insert(@table, {session_id, graph})
    :ok
  end

  @doc "Single-hop attack paths (edges) for a session's stored graph."
  @spec attack_paths(String.t()) :: [edge()]
  def attack_paths(session_id) when is_binary(session_id) do
    get_graph(session_id) |> Map.get(:edges, [])
  end

  @doc "Root nodes (discovered hosts) for a session's graph."
  @spec roots(String.t()) :: [node_id()]
  def roots(session_id) when is_binary(session_id) do
    get_graph(session_id) |> hosts() |> Enum.map(& &1.id)
  end

  @doc "All stored edges whose source is `node_id`, across sessions."
  @spec outgoing_edges(node_id()) :: [edge()]
  def outgoing_edges(node_id) when is_binary(node_id) do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.flat_map(fn {_sid, graph} -> Map.get(graph, :edges, []) end)
    |> Enum.filter(&(&1.source == node_id))
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> :ok
    end
  end

  @doc "Update the graph from a list of structured notes."
  @spec update_from_notes(graph(), [map()]) :: graph()
  def update_from_notes(graph, notes) when is_list(notes) do
    Enum.reduce(notes, graph, fn note, acc ->
      if MapSet.member?(acc.processed_notes, note.key) do
        acc
      else
        process_note(acc, note)
      end
    end)
  end

  @doc "Get all nodes of a specific type."
  @spec nodes_of_type(graph(), String.t()) :: [map()]
  def nodes_of_type(graph, type) do
    graph.nodes
    |> Enum.filter(fn {_id, node} -> node.type == type end)
    |> Enum.map(fn {id, node} -> Map.put(node, :id, id) end)
  end

  @doc "Get all edges of a specific type."
  @spec edges_of_type(graph(), atom()) :: [edge()]
  def edges_of_type(graph, type) do
    Enum.filter(graph.edges, &(&1.type == type))
  end

  @doc "Get all hosts in the graph."
  @spec hosts(graph()) :: [map()]
  def hosts(graph), do: nodes_of_type(graph, "host")

  @doc "Get all services for a specific host."
  @spec services_for_host(graph(), node_id()) :: [map()]
  def services_for_host(graph, host_id) do
    graph.edges
    |> Enum.filter(fn e -> e.source == host_id and e.type == :HAS_SERVICE end)
    |> Enum.map(fn e -> Map.get(graph.nodes, e.target) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Get all credentials that can access a host."
  @spec creds_for_host(graph(), node_id()) :: [map()]
  def creds_for_host(graph, host_id) do
    graph.edges
    |> Enum.filter(fn e -> e.target == host_id and e.type == :AUTH_ACCESS end)
    |> Enum.map(fn e -> Map.get(graph.nodes, e.source) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Get all vulnerabilities for a host."
  @spec vulns_for_host(graph(), node_id()) :: [map()]
  def vulns_for_host(graph, host_id) do
    graph.edges
    |> Enum.filter(fn e -> e.source == host_id and e.type == :HAS_VULNERABILITY end)
    |> Enum.map(fn e -> Map.get(graph.nodes, e.target) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Derive strategic insights from the graph.

  Returns a list of insight strings the orchestrator can use to decide
  next steps:
  - "We have credentials for host X but haven't scanned it yet"
  - "Host X has N open services but no vulnerabilities found"
  - "Host X has a confirmed vulnerability on port Y"
  - "We found credentials on host X — check if they work on other hosts"
  """
  @spec strategic_insights(graph()) :: [String.t()]
  def strategic_insights(graph) do
    [
      unscanned_with_creds(graph),
      services_without_vulns(graph),
      confirmed_vulns(graph),
      lateral_movement_opportunities(graph)
    ]
    |> List.flatten()
  end

  # ── Strategic insight derivations ────────────────────────────────────────

  defp unscanned_with_creds(graph) do
    cred_edges = edges_of_type(graph, :AUTH_ACCESS)

    Enum.map(cred_edges, fn edge ->
      host = Map.get(graph.nodes, edge.target)
      cred = Map.get(graph.nodes, edge.source)

      services = services_for_host(graph, edge.target)

      if host && cred && services == [] do
        "We have credentials for #{host.label} (#{cred.label}) but haven't scanned it yet"
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp services_without_vulns(graph) do
    hosts(graph)
    |> Enum.map(fn host ->
      services = services_for_host(graph, host.id)
      vulns = vulns_for_host(graph, host.id)

      if services != [] and vulns == [] do
        "#{host.label} has #{length(services)} open service(s) but no vulnerabilities found — may need deeper testing"
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp confirmed_vulns(graph) do
    vuln_nodes = nodes_of_type(graph, "vulnerability")

    Enum.map(vuln_nodes, fn vuln ->
      host_edge =
        graph.edges
        |> Enum.find(fn e -> e.target == vuln.id and e.type == :HAS_VULNERABILITY end)

      if host_edge do
        host = Map.get(graph.nodes, host_edge.source)
        "#{host.label} has a confirmed vulnerability: #{vuln.label}"
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp lateral_movement_opportunities(graph) do
    cred_edges = edges_of_type(graph, :AUTH_ACCESS)

    # Group credentials by their source host (where they were found)
    creds_by_source =
      edges_of_type(graph, :CONTAINS)
      |> Enum.group_by(fn e -> e.target end)

    Enum.map(cred_edges, fn edge ->
      host = Map.get(graph.nodes, edge.target)
      cred = Map.get(graph.nodes, edge.source)

      # Check if this credential was found on a different host
      source_hosts =
        Map.get(creds_by_source, edge.source, [])
        |> Enum.map(fn e -> Map.get(graph.nodes, e.source) end)
        |> Enum.reject(&is_nil/1)

      if host && cred && source_hosts != [] do
        source_labels = Enum.map_join(source_hosts, ", ", & &1.label)
        "Credentials found on #{source_labels} may work on #{host.label} — test lateral movement"
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Note processing ───────────────────────────────────────────────────────

  defp process_note(graph, note) do
    hosts = StructuredNotes.extract_hosts(note)
    host_ids = Enum.map(hosts, &"host:#{&1}")

    graph =
      Enum.reduce(host_ids, graph, fn host_id, acc ->
        add_node(acc, host_id, "host", String.replace_prefix(host_id, "host:", ""))
      end)

    graph = process_category(graph, note, host_ids)
    %{graph | processed_notes: MapSet.put(graph.processed_notes, note.key)}
  end

  defp process_category(graph, %{category: :credential} = note, host_ids) do
    cred_id = "credential:#{note.key}"
    username = note.username || "unknown"
    label = "Creds (#{username})"
    graph = add_node(graph, cred_id, "credential", label)

    # Link credential to hosts via AUTH_ACCESS
    Enum.reduce(host_ids, graph, fn host_id, acc ->
      add_edge(acc, cred_id, host_id, :AUTH_ACCESS, %{protocol: note.protocol || "unknown"})
    end)
  end

  defp process_category(graph, %{category: :vulnerability} = note, host_ids) do
    vuln_id = "vulnerability:#{note.key}"
    label = note.cve || "Vulnerability"
    graph = add_node(graph, vuln_id, "vulnerability", label)

    Enum.reduce(host_ids, graph, fn host_id, acc ->
      add_edge(acc, host_id, vuln_id, :HAS_VULNERABILITY, %{})
    end)
  end

  defp process_category(graph, %{category: :finding} = note, host_ids) do
    finding_id = "finding:#{note.key}"
    graph = add_node(graph, finding_id, "finding", note.content || "Finding")

    # Link finding to hosts
    graph =
      Enum.reduce(host_ids, graph, fn host_id, acc ->
        add_edge(acc, host_id, finding_id, :HAS_FINDING, %{})
      end)

    # Process services
    graph = process_services(graph, note, host_ids)

    # Process endpoints
    graph = process_endpoints(graph, note, host_ids)

    # Process technologies
    graph = process_technologies(graph, note, host_ids)

    graph
  end

  defp process_category(graph, %{category: :artifact} = note, host_ids) do
    artifact_id = "artifact:#{note.key}"
    graph = add_node(graph, artifact_id, "artifact", note.content || "Artifact")

    Enum.reduce(host_ids, graph, fn host_id, acc ->
      add_edge(acc, host_id, artifact_id, :HAS_ARTIFACT, %{})
    end)
  end

  defp process_category(graph, _note, _host_ids), do: graph

  defp process_services(graph, note, host_ids) do
    services = StructuredNotes.get_services(note)

    Enum.reduce(services, graph, fn svc, acc ->
      port = svc[:port] || svc["port"]
      product = svc[:product] || svc["product"] || ""
      version = svc[:version] || svc["version"] || ""
      proto = svc[:protocol] || svc["protocol"] || "tcp"

      Enum.reduce(host_ids, acc, fn host_id, acc2 ->
        service_id = "service:#{host_id}:#{port}"

        label = build_service_label(port, proto, product, version)

        acc2 = add_node(acc2, service_id, "service", label, %{product: product, version: version})
        add_edge(acc2, host_id, service_id, :HAS_SERVICE, %{protocol: proto})
      end)
    end)
  end

  defp process_endpoints(graph, note, host_ids) do
    endpoints = StructuredNotes.get_endpoints(note)

    Enum.reduce(endpoints, graph, fn ep, acc ->
      path = ep[:path] || ep["path"]
      methods = ep[:methods] || ep["methods"] || []

      Enum.reduce(host_ids, acc, fn host_id, acc2 ->
        endpoint_id = "endpoint:#{host_id}:#{path}"
        label = path <> if methods != [], do: " (#{Enum.join(methods, ",")})", else: ""
        acc2 = add_node(acc2, endpoint_id, "endpoint", label, %{methods: methods})
        add_edge(acc2, host_id, endpoint_id, :HAS_ENDPOINT, %{})
      end)
    end)
  end

  defp process_technologies(graph, note, host_ids) do
    technologies = StructuredNotes.get_technologies(note)

    Enum.reduce(technologies, graph, fn tech, acc ->
      name = tech[:name] || tech["name"]
      version = tech[:version] || tech["version"] || ""

      Enum.reduce(host_ids, acc, fn host_id, acc2 ->
        tech_id = "technology:#{host_id}:#{name}"
        label = name <> if version != "", do: " #{version}", else: ""
        acc2 = add_node(acc2, tech_id, "technology", label, %{version: version})
        add_edge(acc2, host_id, tech_id, :USES_TECHNOLOGY, %{})
      end)
    end)
  end

  # ── Graph primitives ──────────────────────────────────────────────────────

  defp build_service_label(port, proto, product, version) do
    base = "#{port}/#{proto}"
    parts = [base]
    parts = if product != "", do: parts ++ [" #{product}"], else: parts
    parts = if product != "" and version != "", do: parts ++ [" #{version}"], else: parts
    Enum.join(parts)
  end

  defp add_node(graph, id, type, label, metadata \\ %{}) do
    if Map.has_key?(graph.nodes, id) do
      graph
    else
      node = Map.merge(%{type: type, label: label}, metadata)
      %{graph | nodes: Map.put(graph.nodes, id, node)}
    end
  end

  defp add_edge(graph, source, target, type, metadata) do
    if Map.has_key?(graph.nodes, source) and Map.has_key?(graph.nodes, target) do
      edge = %{source: source, target: target, type: type, metadata: metadata}
      %{graph | edges: graph.edges ++ [edge]}
    else
      graph
    end
  end
end
