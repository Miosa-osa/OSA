defmodule OptimalSystemAgent.Security.AttackPrioritizer do
  @moduledoc """
  Ranks targets by attack value — exploitability × impact × evidence quality.

  The AttackPrioritizer takes the weaponized findings from WeaponCatalog and ranks
  them for optimal exploitation order. It considers:

  - **Exploitability**: How easy is it to exploit? (code reachability, maturity level)
  - **Impact**: CVSS base score, KEV status, lateral movement potential
  - **Evidence quality**: Depth of whitebox analysis, live confirmation status
  - **Attack surface coverage**: Does this target connect to other high-value assets?

  The ranking produces a prioritized list where the highest-scoring targets are
  the most "bang for effort" — fast path to confirmed exploitation.

  ## Usage

      # Rank all weapons by attack value
      ranked = AttackPrioritizer.rank(weapons)

      # Get next target above confidence threshold
      next = AttackPrioritizer.next_above_threshold(ranked, threshold: 0.7)

      # Filter by maturity level
      production_only = AttackPrioritizer.filter_by_maturity(:production, weapons)

  """

  alias OptimalSystemAgent.Security.{ThreatIntel, Cvss}

  @typedoc "Attack priority score"
  @type score() :: float()  # range: 0.0 – 13.0

  @typedoc "Prioritized target entry"
  @type prioritized_entry :: %{
          weapon: map(),
          rank_score: score(),
          exploit_order: integer(),
          confidence: float(),
          is_kev: boolean(),
          lateral_potential: float()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Rank weapons by attack value.

  Computes a composite score for each weapon based on exploitability (30%),
  impact (40%), and evidence quality (30%). Returns the list sorted by
  descending rank_score.

  The ranking considers:
  - Maturity level (production > reliable > poc)
  - KEV status (CISA Known Exploited Vulnerabilities bonus)
  - CVSS base score
  - Code reachability from whitebox analysis
  """
  @spec rank([map()]) :: [prioritized_entry()]
  def rank(weapons) when is_list(weapons) do
    weapons
    |> Enum.with_index(1)
    |> Enum.map(fn {weapon, idx} ->
      %{
        weapon: weapon,
        rank_score: compute_rank_score(weapon),
        exploit_order: idx,
        confidence: Map.get(weapon, :score, 0.5),
        is_kev: Map.get(weapon, :is_kev, false),
        lateral_potential: lateral_potential(weapon)
      }
    end)
    |> Enum.sort_by(& &1.rank_score, :desc)
  end

  @doc """
  Get the next target to attack that meets the confidence threshold.

  Returns `nil` if no targets are available or none meet the threshold.
  Useful for step-by-step exploitation where you want to pick one target at a time.
  """
  @spec next_above_threshold([prioritized_entry()], keyword()) :: map() | nil
  def next_above_threshold(ranked, opts \\ []) when is_list(ranked) do
    threshold = Keyword.get(opts, :threshold, 0.7)

    ranked
    |> Enum.filter(& &1.confidence >= threshold)
    |> List.first()
  end

  @doc """
  Filter weapons by maturity level.

  Returns only weapons matching the specified maturity (poc, reliable, or production).
  Useful for focusing on a specific exploitation stage.
  """
  @spec filter_by_maturity(atom(), [map()]) :: [map()]
  def filter_by_maturity(maturity, weapons) when is_atom(maturity) and is_list(weapons) do
    Enum.filter(weapons, &(&1.maturity == maturity))
  end

  @doc """
  Compute the attack surface score for a weapon.

  Measures how much of the target's attack surface is covered by known classes
  (IDOR, SQLi, SSRF, etc.). Higher scores indicate more exploitable surface area.
  """
  @spec attack_surface_score(map()) :: float()
  def attack_surface_score(weapon) when is_map(weapon) do
    coverage = Map.get(weapon, :surface_coverage, Map.get(weapon, "surface_coverage", 0)) || 0
    classes = Map.get(weapon, :classes_covered, Map.get(weapon, "classes_covered", [])) || []

    # Base score from surface coverage (0–5.0) + class diversity bonus
    base = min(coverage * 2.5, 5.0)
    diversity = Enum.count(classes) * 0.3

    min(base + diversity, 8.0)
  end

  # ── Internal scoring ──────────────────────────────────────────────────────

  @spec compute_rank_score(map()) :: float()
  defp compute_rank_score(weapon) when is_map(weapon) do
    cvss = Map.get(weapon, :cvss_score, Map.get(weapon, "cvss_score", 5.0))
    confidence = Map.get(weapon, :score, 0.5)
    kev_bonus = if Map.get(weapon, :is_kev, false), do: 1.5, else: 0.0
    maturity_bonus = maturity_bonus(Map.get(weapon, :maturity) || :poc)
    exploitability = if Map.get(weapon, :code_reachable, false), do: 1.0, else: 0.3

    # Weighted composite: CVSS (40%), confidence (25%), KEV (15%), maturity (10%), exploitability (10%)
    result = cvss * 0.4 + confidence * 2.5 + kev_bonus + maturity_bonus * 2.0 + exploitability

    min(result, 13.0)
  end

  @spec lateral_potential(map()) :: float()
  defp lateral_potential(weapon) when is_map(weapon) do
    # Higher if the target has multiple known credential types
    # or connects to other high-value assets in ShadowGraph
    credentials = Map.get(weapon, :lateral_credentials, Map.get(weapon, "lateral_credentials", []))
    Enum.count(credentials) * 0.5 + 1.0
  end

  @spec maturity_bonus(atom()) :: float()
  defp maturity_bonus(:production), do: 2.0
  defp maturity_bonus(:reliable), do: 1.0
  defp maturity_bonus(_), do: 0.5
end

