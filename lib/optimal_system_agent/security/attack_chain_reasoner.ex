defmodule OptimalSystemAgent.Security.AttackChainReasoner do
  @moduledoc """
  Multi-hop attack path reasoning over ShadowGraph.

  Walks the ShadowGraph to find connected vulnerability chains — not just
  individual findings, but sequences of vulnerabilities that compound into a
  full exploit (credential → host → lateral movement → privilege escalation).

  Each chain is scored based on:
  - Path cost (edge weights from ShadowGraph)
  - Evidence quality per hop
  - KEV status (CISA Known Exploited Vulnerabilities bonus)
  - Attack surface coverage

  ## Usage

      # Find all chains for a session
      chains = AttackChainReasoner.find_chains(session_id)

      # Get the highest-value chain
      {:ok, best} = AttackChainReasoner.best_chain(session_id)

      # Score a specific path
      score = AttackChainReasoner.score_path(path_nodes)

  """

  alias OptimalSystemAgent.Security.{ShadowGraph, ThreatIntel, Cvss}

  @typedoc "A single hop in an attack chain"
  @type hop :: %{
          source: String.t(),
          target: String.t(),
          edge_weight: float(),
          evidence_quality: float(),
          has_kev: boolean(),
          vulnerability_class: atom() | nil,
          credential_used: String.t() | nil
        }

  @typedoc "A complete attack chain"
  @type chain :: %{
          id: String.t(),
          hops: [hop()],
          start_asset: String.t(),
          end_asset: String.t(),
          total_cost: float(),
          confidence: float(),
          path_description: String.t()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Find all attack chains for a session.

  Walks the ShadowGraph starting from recon roots, following edges that represent
  credential relationships or network connectivity. Returns chains ordered by score.
  """
  @spec find_chains(String.t()) :: [chain()]
  def find_chains(session_id) when is_binary(session_id) do
    graph = ShadowGraph.get_graph(session_id) || %{}

    roots = ShadowGraph.roots(session_id)
    chains = Enum.flat_map(roots, fn root -> explore_from(root, graph) end)

    Enum.sort_by(chains, & &1.confidence, :desc)
  end

  @doc """
  Get the single highest-value attack chain.

  Returns `{:ok, chain}` if at least one chain exists, or `:none` if no paths
  are available in the ShadowGraph.
  """
  @spec best_chain(String.t()) :: {:ok, chain()} | :none
  def best_chain(session_id) when is_binary(session_id) do
    chains = find_chains(session_id)

    case chains do
      [best | _] -> {:ok, best}
      [] -> :none
    end
  end

  @doc """
  Score a specific path (list of nodes/edges).

  Computes: base CVSS score + KEV bonuses + edge weight adjustments.
  Returns confidence in range 0.0–13.0 (CVSS max is ~10, plus bonuses).
  """
  @spec score_path([map()]) :: float()
  def score_path(path) when is_list(path) do
    path
    |> Enum.map(&hop_score/1)
    |> Enum.sum()
    # Cap at reasonable max
    |> min(13.0)
  end

  @doc """
  Extend an existing chain with additional hops from the ShadowGraph.

  Finds unexplored edges connected to the last hop and appends them if they
  meet the minimum evidence threshold (0.4).
  """
  @spec extend(chain()) :: {:extended, chain()} | :unchanged
  def extend(%{hops: hops} = chain) when is_list(hops) do
    last_target = List.last(hops).target
    extensions = ShadowGraph.outgoing_edges(last_target)

    new_hops =
      extensions
      |> Enum.filter(&(&1.evidence_quality >= 0.4))
      |> Enum.map(&to_hop/1)

    if length(new_hops) > 0 do
      extended_chain = %{
        chain
        | hops: hops ++ new_hops,
          confidence: score_path(hops ++ new_hops)
      }

      {:extended, extended_chain}
    else
      :unchanged
    end
  end

  def extend(_), do: :unchanged

  # ── Internal logic ────────────────────────────────────────────────────────

  @spec explore_from(String.t(), map()) :: [chain()]
  defp explore_from(root, graph) when is_binary(root) and is_map(graph) do
    edges = Map.get(graph, root, [])
    paths = []

    Enum.map(edges, fn edge ->
      target = get_target(edge)

      hop = %{
        source: root,
        target: target,
        edge_weight: Map.get(edge, :weight, 1.0),
        evidence_quality: Map.get(edge, :evidence, 0.5),
        has_kev: ThreatIntel.known_exploited?(Map.get(edge, :cve)),
        vulnerability_class: Map.get(edge, :class),
        credential_used: Map.get(edge, :credential)
      }

      %{
        id: "#{root}->#{target}",
        hops: [hop],
        start_asset: root,
        end_asset: target,
        total_cost: hop_score(hop),
        confidence: score_path([hop]),
        path_description: build_description(hop)
      }
    end)
  end

  @spec hop_score(map()) :: float()
  defp hop_score(%{edge_weight: w, evidence_quality: eq, has_kev: kev}) do
    base = Cvss.base_score(w)
    kev_bonus = if kev, do: 1.5, else: 0.0
    base + eq * 2.0 + kev_bonus
  end

  @spec to_hop(map()) :: hop()
  defp to_hop(edge) when is_map(edge) do
    %{
      source: Map.get(edge, :source),
      target: Map.get(edge, :target),
      edge_weight: Map.get(edge, :weight, 1.0),
      evidence_quality: Map.get(edge, :evidence, 0.5),
      has_kev: ThreatIntel.known_exploited?(Map.get(edge, :cve)),
      vulnerability_class: Map.get(edge, :class),
      credential_used: Map.get(edge, :credential)
    }
  end

  @spec get_target(map()) :: String.t()
  defp get_target(%{target: t}) when is_binary(t), do: t
  defp get_target(%{"target" => t}) when is_binary(t), do: t
  defp get_target(edge) when is_map(edge), do: Map.get(edge, :node, "unknown")

  @spec build_description(hop()) :: String.t()
  defp build_description(%{vulnerability_class: class, has_kev: kev}) when is_atom(class) do
    base = "#{String.upcase(to_string(class))}"
    if kev, do: base <> " (KEV)", else: base
  end

  @spec build_description(hop()) :: String.t()
  defp build_description(%{vulnerability_class: nil}), do: "connection"
end
