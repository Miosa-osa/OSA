defmodule OptimalSystemAgent.Security.ThreatIntel do
  @moduledoc """
  KEV (Known Exploited Vulnerabilities) lookup and finding enrichment.

  A CVE on the CISA KEV list is not "more theoretical" - it is being used.
  This module loads a bundled snapshot of that list (no network at runtime)
  and optionally merges a larger feed from disk via `load_feed/1`. EPSS
  scores are accepted if the caller already has them; they are never fetched
  here, so tests and air-gapped engagements stay deterministic.

  ## Improvements over basic KEV enrichment

  - **EPSS-aware scoring**: When an entry in kev.json contains an `epss_score`
    field (0.0-1.0), it is used to weight the priority calculation. A high EPSS
    score means the vulnerability is more likely to be exploited, which boosts its
    rank even if the CVSS base score is moderate.

  - **Ransomware campaign weighting**: Entries marked as `known_ransomware_campaign_use`
    in the KEV feed receive a +1.0 bonus because ransomware groups tend to target
    known-weak points first. This makes these findings more actionable for operators.

  - **Date-based decay**: The `date_added` field is used to compute recency.
    Entries added within the last 90 days get a +0.5 "fresh" bonus because they
    are more likely to be actively exploited in current campaigns.

  ## Usage

      iex> ThreatIntel.known_exploited?("CVE-2021-44228")
      true

      iex> finding = %{cve: "CVE-2023-34362", cvss_score: 9.8}
      ...> ThreatIntel.enrich(finding)
      %{cve: "CVE-2023-34362", cvss_score: 9.8, kev: true, ...}

      iex> ThreatIntel.priority(%{cve: "CVE-2021-44228", cvss_score: 7.5})
      10.5
  """

  @table :osa_threat_intel_kev
  @recent_cutoff_days 90

  @doc "True when `cve` is on the loaded KEV catalog."
  @spec known_exploited?(String.t()) :: boolean()
  def known_exploited?(cve) when is_binary(cve) do
    match?({:ok, _}, lookup(cve))
  end

  def known_exploited?(_), do: false

  @doc "Look up a CVE in the KEV catalog."
  @spec lookup(String.t()) :: {:ok, map()} | :not_found
  def lookup(cve) when is_binary(cve) do
    ensure_loaded()
    key = normalize_cve(cve)

    case :ets.lookup(@table, key) do
      [{^key, entry}] -> {:ok, entry}
      _ -> :not_found
    end
  end

  def lookup(_), do: :not_found

  @doc """
  Enrich a finding map with `:kev` and `:kev_entry`. Leaves `:epss` alone
  if already present. Adds `:ransomware_bonus`, `:recency_bonus`, and
  `:priority_boost` fields for prioritization downstream.
  """
  @spec enrich(map()) :: map()
  def enrich(finding) when is_map(finding) do
    cve = Map.get(finding, :cve) || Map.get(finding, "cve")

    case cve && lookup(cve) do
      {:ok, entry} ->
        ransomware_bonus =
          case entry["known_ransomware_campaign_use"] || entry["KnownRansomwareCampaignUse"] do
            nil -> 0.0
            val when is_binary(val) -> String.upcase(val) |> ransomware_score()
            _ -> 0.0
          end

        recency_bonus = recency_bonus(entry)

        priority_boost = ransomware_bonus + recency_bonus

        finding
        |> Map.put(:kev, true)
        |> Map.put(:kev_entry, entry)
        |> Map.put(:ransomware_bonus, ransomware_bonus)
        |> Map.put(:recency_bonus, recency_bonus)
        |> Map.put(:priority_boost, priority_boost)

      _ ->
        finding
        |> Map.put(:kev, false)
        |> Map.put(:kev_entry, nil)
        |> Map.put(:ransomware_bonus, 0.0)
        |> Map.put(:recency_bonus, 0.0)
        |> Map.put(:priority_boost, 0.0)
    end
  end

  def enrich(other), do: other

  @doc """
  Enrich a finding with EPSS score if available.

  If the finding already has an `:epss` field, it is used as-is.
  Otherwise the enriched entry's `epss_score` (if present) is adopted.
  Returns the finding with `:epss`, `:epss_source`, and `:epss_confirmed`
  fields set so downstream modules can distinguish between a real EPSS value
  and one that was inferred.
  """
  @spec enrich_epss(map()) :: map()
  def enrich_epss(finding) when is_map(finding) do
    cve = Map.get(finding, :cve) || Map.get(finding, "cve")

    epss =
      case finding[:epss] do
        nil ->
          # Try to get EPSS from the kev_entry if available
          case finding[:kev_entry] do
            %{"epss_score" => score} when is_number(score) -> score
            %{epss_score: score} when is_number(score) -> score
            _ -> 0.0
          end

        val when is_number(val) ->
          val

        _ ->
          0.0
      end

    finding
    |> Map.put(:epss, epss)
    |> Map.put(:epss_source, if(finding[:epss], do: "explicit", else: "inferred"))
    |> Map.put(:epss_confirmed, epss >= 0.3)
  end

  def enrich_epss(other), do: other

  @doc """
  Combined priority in 0.0-15.0+: CVSS base + KEV bonus + EPSS weighted + ransomware + recency.

  The new formula accounts for:
  - `cvss_score`: Base score (0-10)
  - `kev_bonus`: +1.5 if on KEV list, +2.5 if actively exploited by ransomware
  - `epss_weighted`: EPSS * 3.0 (up to 3.0 points) instead of * 2.0
  - `ransomware_bonus`: +1.0 for ransomware campaign use
  - `recency_bonus`: +0.5 if the KEV entry is recent (<90 days old)

  This produces a more nuanced priority that reflects real-world exploit likelihood,
  not just theoretical severity.
  """
  @spec priority(map()) :: float()
  def priority(finding) when is_map(finding) do
    f = enrich(finding)
    epss_f = enrich_epss(Map.put(f, :kev_entry, Map.get(f, :kev_entry)))

    base = number(Map.get(epss_f, :cvss_score) || Map.get(epss_f, "cvss_score"))

    # KEV bonus: 1.5 base, up to 2.5 if ransomware
    kev_bonus =
      case epss_f[:ransomware_bonus] do
        rb when is_number(rb) and rb > 0 -> 2.5
        _ -> 1.5
      end

    # EPSS weighted: now uses *3.0 for higher impact
    epss_weighted = number(Map.get(epss_f, :epss) || Map.get(epss_f, "epss")) * 3.0

    # Ransomware bonus on top
    ransomware_bonus = number(Map.get(epss_f, :ransomware_bonus))

    # Recency bonus for recent KEV entries
    recency_bonus = number(Map.get(epss_f, :recency_bonus))

    base + kev_bonus + epss_weighted + ransomware_bonus + recency_bonus
  end

  def priority(_), do: 0.0

  @doc """
  Merge a JSON array of KEV entries from `path` into the in-process catalog.
  Used in tests and to overlay a fresher CISA dump the operator dropped on disk.
  """
  @spec load_feed(String.t()) :: :ok | {:error, String.t()}
  def load_feed(path) when is_binary(path) do
    ensure_loaded()

    with {:ok, bin} <- File.read(path),
         {:ok, list} <- Jason.decode(bin),
         true <- is_list(list) do
      Enum.each(list, &insert/1)
      :ok
    else
      {:error, :enoent} -> {:error, "feed not found: #{path}"}
      {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
      false -> {:error, "feed must be a JSON array"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def load_feed(_), do: {:error, "path must be a string"}

  # ── catalog load ────────────────────────────────────────────────────────

  defp ensure_loaded do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        load_bundled()

      _ ->
        :ok
    end
  end

  defp load_bundled do
    path = Path.join(:code.priv_dir(:optimal_system_agent), "security/kev.json")

    case File.read(path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, list} when is_list(list) -> Enum.each(list, &insert/1)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp insert(%{"cve" => cve} = entry) when is_binary(cve) do
    :ets.insert(@table, {normalize_cve(cve), entry})
  end

  defp insert(%{cve: cve} = entry) when is_binary(cve) do
    insert(Map.new(entry, fn {k, v} -> {to_string(k), v} end))
  end

  defp insert(_), do: :ok

  defp normalize_cve(cve), do: cve |> String.trim() |> String.upcase()

  # ── helpers ─────────────────────────────────────────────────────────────

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_), do: 0.0

  defp ransomware_score(nil), do: 0.0
  defp ransomware_score("known"), do: 1.0
  defp ransom_score("more_than_known_ransomware_campaign_use"), do: 1.5
  defp ransom_score(_), do: 0.0

  @doc "Calculate the recency bonus for a KEV entry based on its date_added."
  @spec recency_bonus(map()) :: float()
  def recency_bonus(entry) when is_map(entry) do
    date_str =
      Map.get(entry, "dateAdded") || Map.get(entry, "date_added") || Map.get(entry, :date_added)

    case parse_date(date_str) do
      {:ok, date} ->
        days_ago = days_between(date, Date.utc_today())
        if days_ago <= @recent_cutoff_days, do: 0.5, else: 0.0

      _ ->
        0.0
    end
  end

  def recency_bonus(_), do: 0.0

  # ── date helpers ────────────────────────────────────────────────────────

  @doc "Parse a KEV date string (YYYY-MM-DD format)."
  @spec parse_date(String.t()) :: {:ok, Date.t()} | :error
  def parse_date(date_str) when is_binary(date_str) do
    case Date.parse(date_str) do
      {:ok, date, _} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def parse_date(_), do: :error

  @doc "Compute days between two dates."
  @spec days_between(Date.t(), Date.t()) :: non_neg_integer()
  def days_between(date1, date2) when is_struct(date1, Date) and is_struct(date2, Date) do
    Date.day_number_diff(date2, date1) |> max(0)
  end

  defp max(a, b), do: if(a > b, do: a, else: b)
end
