defmodule OptimalSystemAgent.Security.ReportGate do
  @moduledoc """
  Report-eligibility gate for security findings.

  A finding that cannot be ranked (no CVSS), classified (no CWE), or shown
  (no evidence) is not report-grade. This module is the cheap capstone of the
  reporting foundation: score, map, or reject - never fabricate a severity.
  """

  alias OptimalSystemAgent.Security.{Cvss, CweCatalog}

  @doc "True when `evaluate/1` would return `{:ok, _}`."
  @spec eligible?(map()) :: boolean()
  def eligible?(finding) when is_map(finding) do
    match?({:ok, _}, evaluate(finding))
  end

  def eligible?(_), do: false

  @doc """
  Validate and enrich a finding.

  Accepts atom or string keys. On success the returned map has atom keys
  `cvss_score`, `severity`, `cwe`, and `owasp` filled in from the vector and
  catalog. On failure returns `{:error, reasons}` with every missing piece,
  so the caller can fix rather than guess.
  """
  @spec evaluate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def evaluate(finding) when is_map(finding) do
    f = atomize(finding)
    class = vuln_class(f)
    vector = field(f, :cvss_vector)
    cwe = field(f, :cwe) || (class && CweCatalog.cwe(class))
    catalog = class && CweCatalog.lookup(class)

    {score_ok, score, severity, vector_reason} = score_vector(vector)

    reasons =
      []
      |> maybe_add(not score_ok, vector_reason || "missing CVSS vector")
      |> maybe_add(not present?(cwe), "missing CWE")
      |> maybe_add(
        not has_evidence?(f),
        "missing evidence (poc, evidence_path, or confirmed status)"
      )

    if reasons == [] do
      {:ok,
       f
       |> Map.put(:cvss_vector, vector)
       |> Map.put(:cvss_score, score)
       |> Map.put(:severity, severity)
       |> Map.put(:cwe, cwe)
       |> Map.put(:owasp, field(f, :owasp) || (catalog && catalog.owasp))}
    else
      {:error, reasons}
    end
  end

  def evaluate(_), do: {:error, ["finding must be a map"]}

  @doc "Keep only report-eligible findings, enriched."
  @spec filter([map()]) :: [map()]
  def filter(findings) when is_list(findings) do
    Enum.flat_map(findings, fn f ->
      case evaluate(f) do
        {:ok, enriched} -> [enriched]
        _ -> []
      end
    end)
  end

  def filter(_), do: []

  defp score_vector(vector) when is_binary(vector) and vector != "" do
    case Cvss.score(vector) do
      {:ok, %{base_score: s, severity: sev}} -> {true, s, sev, nil}
      {:error, reason} -> {false, nil, nil, "invalid CVSS vector: #{reason}"}
    end
  end

  defp score_vector(_), do: {false, nil, nil, "missing CVSS vector"}

  defp has_evidence?(f) do
    present?(field(f, :poc)) or present?(field(f, :evidence_path)) or
      field(f, :status) in [:confirmed, "confirmed"]
  end

  defp vuln_class(f) do
    case field(f, :vuln_class) do
      a when is_atom(a) ->
        a

      s when is_binary(s) ->
        try do
          String.to_existing_atom(s)
        rescue
          ArgumentError -> nil
        end

      _ ->
        nil
    end
  end

  @known_keys ~w(vuln_class cvss_vector cwe owasp poc evidence_path status reasoning source sink)a

  defp atomize(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        case Enum.find(@known_keys, &(Atom.to_string(&1) == k)) do
          nil -> acc
          atom -> Map.put(acc, atom, v)
        end

      _, acc ->
        acc
    end)
  end

  defp field(map, key), do: Map.get(map, key)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp maybe_add(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add(reasons, false, _), do: reasons
end
