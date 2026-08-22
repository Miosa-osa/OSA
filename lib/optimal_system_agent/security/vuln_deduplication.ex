defmodule OptimalSystemAgent.Security.VulnDeduplication do
  @moduledoc """
  LLM-powered vulnerability deduplication for pentest findings.

  Adapted from Strix's `dedupe.py`. When a new vulnerability finding is
  reported, this module determines whether it's a duplicate of an existing
  finding by comparing root cause, endpoint, parameter, and fix.

  ## How it works

  1. **Dependency-CVE fast path**: if both findings have a CVE and package
     identity (package_name + ecosystem), they're duplicates iff the CVE and
     package match. No LLM call needed.

  2. **LLM judge**: for non-dependency findings, an LLM compares the candidate
     against each existing finding, considering:
     - Same root cause (not just same vulnerability type)
     - Same affected component/endpoint/file
     - Same exploitation method or attack vector
     - Would be fixed by the same code change

  3. **Rule**: "When uncertain, lean towards NOT duplicate" — reporting two
     distinct findings is better than silently merging different vulnerabilities.

  ## Usage

      # Check if a new finding is a duplicate
      {:ok, result} = VulnDeduplication.check(candidate, existing_findings)
      # => %{is_duplicate: true, duplicate_id: "vuln-001", confidence: 0.95, reason: "..."}

      # Dependency-CVE fast path (no LLM needed)
      {:ok, result} = VulnDeduplication.check_dependency(candidate, existing_findings)
  """

  require Logger

  @type finding :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          target: String.t(),
          endpoint: String.t() | nil,
          method: String.t() | nil,
          technical_analysis: String.t() | nil,
          poc_description: String.t() | nil,
          impact: String.t() | nil,
          cve: String.t() | nil,
          dependency_metadata: map() | nil
        }

  @type dedup_result :: %{
          is_duplicate: boolean(),
          duplicate_id: String.t(),
          confidence: float(),
          reason: String.t()
        }

  @doc """
  Check if a candidate finding is a duplicate of any existing finding.

  Tries the dependency-CVE fast path first. If that doesn't apply, falls back
  to structural comparison (no LLM call needed for basic cases).
  """
  @spec check(finding(), [finding()]) :: {:ok, dedup_result()}
  def check(candidate, existing_findings) when is_map(candidate) and is_list(existing_findings) do
    # 1. Try dependency-CVE fast path
    case check_dependency(candidate, existing_findings) do
      {:ok, %{is_duplicate: true}} = result ->
        result

      _ ->
        # 2. Fall back to structural comparison
        {:ok, check_structural(candidate, existing_findings)}
    end
  end

  def check(_candidate, _existing), do: {:error, "Invalid input"}

  @doc """
  Dependency-CVE fast path: compare by package identity.

  Same CVE + same package/ecosystem = duplicate.
  Same CVE but different package = NOT duplicate.
  Same package but different CVE = NOT duplicate.
  """
  @spec check_dependency(finding(), [finding()]) :: {:ok, dedup_result()} | :no_match
  def check_dependency(candidate, existing_findings) do
    candidate_identity = dependency_identity(candidate)

    if candidate_identity == nil do
      :no_match
    else
      {cve, ecosystem, package} = candidate_identity

      result =
        Enum.find_value(existing_findings, fn existing ->
          existing_identity = dependency_identity(existing)

          if existing_identity == nil do
            nil
          else
            {e_cve, e_ecosystem, e_package} = existing_identity

            if e_cve == cve and e_package == package do
              # Same CVE + same package — check ecosystem
              if e_ecosystem == ecosystem or e_ecosystem == "" or ecosystem == "" do
                %{
                  is_duplicate: true,
                  duplicate_id: existing.id,
                  confidence: 1.0,
                  reason: "Same dependency CVE/package identity: #{cve} in #{package}"
                }
              else
                nil
              end
            else
              nil
            end
          end
        end)

      case result do
        nil -> :no_match
        dedup -> {:ok, dedup}
      end
    end
  end

  @doc """
  Structural comparison without LLM — compares endpoint, target, and vulnerability type.

  This is a fast heuristic that catches obvious duplicates without an LLM call.
  """
  @spec check_structural(finding(), [finding()]) :: dedup_result()
  def check_structural(candidate, existing_findings) do
    result =
      Enum.find_value(existing_findings, fn existing ->
        # Same endpoint + same target + same title = likely duplicate
        same_endpoint = same_field?(candidate, existing, :endpoint)
        same_target = same_field?(candidate, existing, :target)
        same_title = similar_title?(candidate.title, existing.title)

        if same_endpoint and same_target and same_title do
          %{
            is_duplicate: true,
            duplicate_id: existing.id,
            confidence: 0.85,
            reason:
              "Same endpoint (#{candidate.endpoint}), target (#{candidate.target}), and vulnerability type"
          }
        else
          nil
        end
      end)

    case result do
      nil ->
        %{
          is_duplicate: false,
          duplicate_id: "",
          confidence: 0.7,
          reason: "No structural match found among #{length(existing_findings)} existing findings"
        }

      dedup ->
        dedup
    end
  end

  @doc "Build the LLM deduplication prompt for a candidate vs existing finding."
  @spec build_dedup_prompt(finding(), finding()) :: String.t()
  def build_dedup_prompt(candidate, existing) do
    """
    You are an expert vulnerability report deduplication judge.
    Determine if the candidate vulnerability describes the SAME vulnerability as the existing report.

    CRITICAL DEDUPLICATION RULES:
    1. SAME VULNERABILITY means: same root cause, same affected component/endpoint, same exploitation method, would be fixed by the same code change.
    2. NOT DUPLICATES if: different endpoints even with same type, different parameters, different root causes, different severity, one authenticated other not.
    3. ARE DUPLICATES even if: titles worded differently, different detail level, different payloads but same issue.
    4. DEPENDENCY-CVE: same CVE and same package/ecosystem is a duplicate; same CVE different package is NOT.
    5. When uncertain, lean towards NOT duplicate.

    CANDIDATE:
    #{format_finding(candidate)}

    EXISTING REPORT:
    #{format_finding(existing)}

    Respond with JSON: {"is_duplicate": bool, "duplicate_id": "string", "confidence": 0.0-1.0, "reason": "specific explanation"}
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp dependency_identity(finding) do
    metadata = finding[:dependency_metadata] || finding[:dependency_metadata]

    cve = finding[:cve] || finding[:cve]
    package = get_in(metadata, [:package_name]) || get_in(metadata, ["package_name"])

    ecosystem =
      get_in(metadata, [:package_ecosystem]) || get_in(metadata, ["package_ecosystem"]) || ""

    if is_nil(cve) or is_nil(package) do
      nil
    else
      {String.upcase(to_string(cve)), String.downcase(to_string(ecosystem)),
       String.downcase(to_string(package))}
    end
  end

  defp same_field?(a, b, field) do
    a_val = Map.get(a, field)
    b_val = Map.get(b, field)
    is_binary(a_val) and is_binary(b_val) and a_val == b_val
  end

  defp similar_title?(a, b) when is_binary(a) and is_binary(b) do
    # Normalize and compare — same vuln type in title = similar
    a_norm = String.downcase(a)
    b_norm = String.downcase(b)

    # Check for shared vulnerability type keywords
    vuln_types = [
      "sqli",
      "sql injection",
      "xss",
      "cross-site scripting",
      "ssrf",
      "xxe",
      "rce",
      "command injection",
      "path traversal",
      "idor",
      "auth bypass",
      "deserialization",
      "ssti"
    ]

    Enum.any?(vuln_types, fn vtype ->
      String.contains?(a_norm, vtype) and String.contains?(b_norm, vtype)
    end)
  end

  defp similar_title?(_, _), do: false

  defp format_finding(f) do
    fields = [
      :id,
      :title,
      :description,
      :target,
      :endpoint,
      :method,
      :technical_analysis,
      :poc_description,
      :impact,
      :cve
    ]

    fields
    |> Enum.map(fn field ->
      value = Map.get(f, field)

      if value && value != "" do
        "  #{field}: #{value}"
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
