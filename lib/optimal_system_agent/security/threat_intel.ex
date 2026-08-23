defmodule OptimalSystemAgent.Security.ThreatIntel do
  @moduledoc """
  KEV (Known Exploited Vulnerabilities) lookup and finding enrichment.

  A CVE on the CISA KEV list is not "more theoretical" - it is being used.
  This module loads a bundled snapshot of that list (no network at runtime)
  and optionally merges a larger feed from disk via `load_feed/1`. EPSS
  scores are accepted if the caller already has them; they are never fetched
  here, so tests and air-gapped engagements stay deterministic.
  """

  @table :osa_threat_intel_kev

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
  if already present.
  """
  @spec enrich(map()) :: map()
  def enrich(finding) when is_map(finding) do
    cve = Map.get(finding, :cve) || Map.get(finding, "cve")

    case cve && lookup(cve) do
      {:ok, entry} ->
        finding
        |> Map.put(:kev, true)
        |> Map.put(:kev_entry, entry)

      _ ->
        finding
        |> Map.put(:kev, false)
        |> Map.put(:kev_entry, nil)
    end
  end

  def enrich(other), do: other

  @doc """
  Combined priority in 0.0-13.0: CVSS base + 1.5 if KEV + 2*EPSS (0-1).
  Missing pieces contribute 0.
  """
  @spec priority(map()) :: float()
  def priority(finding) when is_map(finding) do
    f = enrich(finding)
    base = number(Map.get(f, :cvss_score) || Map.get(f, "cvss_score"))
    kev_bonus = if Map.get(f, :kev) == true, do: 1.5, else: 0.0
    epss = number(Map.get(f, :epss) || Map.get(f, "epss"))
    base + kev_bonus + epss * 2.0
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

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_), do: 0.0
end
