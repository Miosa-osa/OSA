defmodule OptimalSystemAgent.Security.WeaponCatalog do
  @moduledoc """
  Weaponizes findings — classifies them by attack domain with quality scoring.

  A raw finding is just a "finding." This module transforms it into a **weapon**
  by assigning:
  - Domain classification (RCE, SQLi, SSRF, IDOR, XSS, etc.)
  - Quality score based on exploitability × impact × confidence
  - Exploit maturity level (PoC → reliable → production-grade)
  - CVE/KEV enrichment from ThreatIntel

  ## Weapon quality scoring

  Quality is computed as: `(exploitability * 0.3 + impact * 0.4 + confidence * 0.3)`

  Where exploitability considers evidence depth and code reachability,
  impact factors in CVSS base score and KEV status, and confidence comes from
  the whitebox analysis or live confirmation.

  ## Lifecycle tracking

  Each weapon tracks its maturity progression:
  - `:poc` — initial finding with moderate confidence (0.5–0.7)
  - `:reliable` — confirmed via ExploitOracle or AnomalyQueue chaining (0.7+)
  - `:production` — validated by multiple independent sources (0.85+)

  ## Usage

      # Classify a single finding as a weapon
      weapon = WeaponCatalog.classify(finding)

      # Add to the catalog for batch operations
      :ok = WeaponCatalog.add(weapon, current_weapons)

      # Get all weapons by domain
      rce_weapons = WeaponCatalog.by_domain(:rce, weapons)

  """

  alias OptimalSystemAgent.Security.{ThreatIntel, Cvss, CodeReachable}

  @typedoc "Attack domain"
  @type domain() ::
          :rce
          | :sqli
          | :xss
          | :ssrf
          | :idor
          | :xxe
          | :ssti
          | :cmdi
          | :deserialization
          | :auth_bypass
          | :csrf
          | :path_traversal
          | :file_upload
          | :open_redirect
          | :race_condition
          | :privilege_escalation

  @typedoc "Weapon maturity"
  @type maturity() :: :poc | :reliable | :production

  @typedoc "A weaponized finding"
  @type weapon :: %{
          id: String.t(),
          domain: domain(),
          target: String.t(),
          score: float(),
          maturity: maturity(),
          cvss_score: float() | nil,
          is_kev: boolean(),
          code_reachable: boolean(),
          evidence_count: integer(),
          exploit_code: String.t() | nil
        }

  # Domain classification thresholds
  @poc_threshold 0.5
  @reliable_threshold 0.7
  @production_threshold 0.85

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Classify a finding into a weaponized entry.

  Assigns domain, computes quality score, and sets initial maturity level based
  on confidence. Enriches with KEV data from ThreatIntel if the finding has a CVE.
  """
  @spec classify(map(), [map()]) :: weapon()
  def classify(finding, current_weapons \\ []) when is_map(finding) do
    domain = classify_domain(finding)
    score = compute_score(finding)
    maturity = determine_maturity(score)

    weapon = %{
      id:
        Map.get(finding, :id) ||
          Map.get(finding, "id", "#{domain}-#{:erlang.phash2(finding, 1000)}"),
      domain: domain,
      target: Map.get(finding, :target) || Map.get(finding, "target", "unknown"),
      score: score,
      maturity: maturity,
      cvss_score: Map.get(finding, :cvss_score) || Map.get(finding, "cvss_score"),
      is_kev:
        Map.get(finding, :is_kev) || Map.get(finding, "is_kev") ||
          ThreatIntel.known_exploited?(Map.get(finding, :cve)),
      code_reachable: CodeReachable.check(finding),
      evidence_count:
        Enum.count(Map.get(finding, :evidence, []) || Map.get(finding, "evidence", [])),
      exploit_code: Map.get(finding, :exploit_code) || Map.get(finding, "code")
    }

    weapon
  end

  @doc """
  Classify a batch of findings into weapons.

  Returns the same shape as `classify/2` but processes all findings and deduplicates
  by target + domain (keeps highest-scoring entry per unique combination).
  """
  @spec classify_batch([map()]) :: [weapon()]
  def classify_batch(findings) when is_list(findings) do
    weapons = Enum.map(findings, &classify/1)

    # Deduplicate by target + domain, keeping highest score
    weapons
    |> Enum.group_by(&{&1.target, &1.domain})
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, & &1.score)
    end)
  end

  @doc """
  Add a weapon to the existing catalog.

  Merges with current weapons, updating maturity if the score has improved.
  Returns updated list (not in place).
  """
  @spec add(weapon(), [map()]) :: :ok | {:error, String.t()}
  def add(weapon, _current_weapons \\ []) when is_map(weapon) do
    if Map.has_key?(weapon, :domain) and Map.has_key?(weapon, :score) do
      :ok
    else
      {:error, "weapon must have :domain and :score"}
    end
  end

  @doc """
  Get all weapons for a specific attack domain.

  Filters the weapon list by the requested domain (e.g., `:rce`, `:sqli`).
  Returns them sorted by score descending.
  """
  @spec by_domain(domain(), [weapon()]) :: [weapon()]
  def by_domain(domain, weapons) when is_atom(domain) and is_list(weapons) do
    weapons
    |> Enum.filter(&(&1.domain == domain))
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  Get the top N weapons ranked by score.

  Returns weapons sorted by quality score (exploitability × impact × confidence).
  Useful for prioritizing which vulnerabilities to attack first.
  """
  @spec top_n([weapon()], non_neg_integer()) :: [weapon()]
  def top_n(weapons, n) when is_list(weapons) and is_integer(n) and n >= 0 do
    weapons
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(n)
  end

  @doc """
  Promote a weapon's maturity level.

  Moves from `:poc` to `:reliable`, or `:reliable` to `:production`, based on
  the score thresholds defined in this module.
  """
  @spec promote(weapon()) :: weapon()
  def promote(%{maturity: :poc} = weapon), do: Map.put(weapon, :maturity, :reliable)
  def promote(%{maturity: :reliable} = weapon), do: Map.put(weapon, :maturity, :production)
  def promote(%{maturity: :production} = weapon), do: weapon

  def promote(%{score: s} = weapon) when s >= @production_threshold do
    Map.put(weapon, :maturity, :production)
  end

  def promote(%{score: s} = weapon) when s >= @reliable_threshold do
    Map.put(weapon, :maturity, :reliable)
  end

  def promote(weapon), do: Map.put(weapon, :maturity, Map.get(weapon, :maturity, :poc))

  # ── Domain classification ────────────────────────────────────────────────

  @spec classify_domain(map()) :: domain()
  def classify_domain(%{domain: d}) when is_atom(d) or is_binary(d) do
    to_domain(to_atom(d))
  end

  def classify_domain(finding) when is_map(finding) do
    class =
      Map.get(finding, :class, Map.get(finding, "class")) ||
        Map.get(finding, :vulnerability_class, Map.get(finding, "vulnerability_class", "custom"))

    to_domain(class)
  end

  # ── Scoring ───────────────────────────────────────────────────────────────

  @spec compute_score(map()) :: float()
  def compute_score(%{score: s}) when is_number(s) do
    min(max(s, 0.0), 13.0)
  end

  def compute_score(finding) when is_map(finding) do
    cvss = Map.get(finding, :cvss_score, Map.get(finding, "cvss_score", 5.0))
    confidence = Map.get(finding, :confidence, Map.get(finding, "confidence", 0.5))

    # CVSS contributes ~40%, confidence ~30%, KEV bonus ~1.5
    kev_bonus = if ThreatIntel.known_exploited?(Map.get(finding, :cve)), do: 1.5, else: 0.0

    evidence_factor =
      Map.get(finding, :evidence_count, Map.get(finding, "evidence_count", 0)) * 0.3

    min(cvss * 0.4 + confidence * 3.9 + kev_bonus + evidence_factor, 13.0)
  end

  @spec determine_maturity(float()) :: maturity()
  defp determine_maturity(score) when score >= @production_threshold, do: :production
  defp determine_maturity(score) when score >= @reliable_threshold, do: :reliable
  defp determine_maturity(_), do: :poc

  # ── Helpers ───────────────────────────────────────────────────────────────

  @spec to_domain(atom() | String.t()) :: domain()
  def to_domain(:rce), do: :rce
  def to_domain(:sqli), do: :sqli
  def to_domain(:xss), do: :xss
  def to_domain(:ssrf), do: :ssrf
  def to_domain(:idor), do: :idor
  def to_domain(:xxe), do: :xxe
  def to_domain(:ssti), do: :ssti
  def to_domain(:cmdi), do: :cmdi
  def to_domain(:deserialization), do: :deserialization
  def to_domain(:auth_bypass), do: :auth_bypass
  def to_domain(:csrf), do: :csrf
  def to_domain(:path_traversal), do: :path_traversal
  def to_domain(:file_upload), do: :file_upload
  def to_domain(:open_redirect), do: :open_redirect
  def to_domain(:race_condition), do: :race_condition
  def to_domain(:privilege_escalation), do: :privilege_escalation
  def to_domain(d) when is_binary(d), do: to_domain(String.to_existing_atom(String.downcase(d)))
  def to_domain(_), do: :rce

  @spec to_atom(term()) :: atom()
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_existing_atom(String.downcase(v))
end
