defmodule OptimalSystemAgent.Security.SarifReport do
  @moduledoc """
  SARIF 2.1.0 report output for pentest findings (Tier 3 #11).

  Adapted from Strix's SARIF report generator. Renders the session's
  vulnerability findings into a valid SARIF (Static Analysis Results
  Interchange Format) 2.1.0 JSON document — the industry-standard format
  for exchanging security findings between tools, consumed by GitHub Code
  Scanning, Azure DevOps, and SIEM pipelines.

  ## Structure produced

      {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
          "tool": {"driver": {"name": "OSA", "version": "...", "informationUri": "..."}},
          "results": [ {ruleId, level, message, locations, partialFingerprints, ...} ],
          "invocations": [{...}]
        }]
      }

  ## Source

  Findings are read from the session's `Security.NotesStore` — all notes of
  category `:vulnerability` and `:finding`. Vulnerability notes become
  `results[]` entries; finding notes become supporting `locations` where they
  describe endpoints/services on the same target.

  ## Severity mapping

  Note `confidence` (`:high`/`::medium`/`:low`) maps to SARIF `level`:
  `error` / `warning` / `note`. Note `status` is carried in `properties`.

  ## Usage

      {:ok, sarif} = SarifReport.generate(session_id)
      SarifReport.generate(session_id, to_file: true)  # writes to a path
  """

  require Logger

  alias OptimalSystemAgent.Security.NotesStore

  @sarif_schema "https://json.schemastore.org/sarif-2.1.0.json"
  @sarif_version "2.1.0"
  @tool_name "OSA"
  @tool_info_uri "https://github.com/Miosa-osa/OSA"

  @doc "Generate a SARIF 2.1.0 report from the session's vulnerability notes."
  @spec generate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      notes = NotesStore.list(session_id)
      vuln_notes = Enum.filter(notes, &(&1.category == :vulnerability))

      results = Enum.map(vuln_notes, &note_to_result/1)
      rules = build_rules(vuln_notes)

      report = %{
        "$schema" => @sarif_schema,
        "version" => @sarif_version,
        "runs" => [
          %{
            "tool" => %{
              "driver" => %{
                "name" => @tool_name,
                "version" => tool_version(),
                "informationUri" => @tool_info_uri,
                "rules" => rules
              }
            },
            "results" => results,
            "invocations" => [
              %{
                "executionSuccessful" => true,
                "startTimeUtc" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            ]
          }
        ]
      }

      case Keyword.get(opts, :to_file) do
        true ->
          path = Keyword.get(opts, :path) || default_path(session_id)

          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, Jason.encode!(report, pretty: true)) do
            {:ok, %{report: report, path: path}}
          end

        path when is_binary(path) ->
          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, Jason.encode!(report, pretty: true)) do
            {:ok, %{report: report, path: path}}
          end

        _ ->
          {:ok, report}
      end
    end
  end

  @doc "Validate a SARIF report map against the required top-level structure."
  @spec valid?(map()) :: boolean()
  def valid?(%{"version" => "2.1.0", "runs" => runs}) when is_list(runs) do
    Enum.all?(runs, &run_valid?/1)
  end

  def valid?(_), do: false

  @doc "Validate a single SARIF run entry."
  @spec run_valid?(map()) :: boolean()
  def run_valid?(%{"tool" => %{"driver" => driver}, "results" => results})
      when is_map(driver) and is_list(results) do
    Map.has_key?(driver, "name") and Enum.all?(results, &result_valid?/1)
  end

  def run_valid?(_), do: false

  @doc "Validate a single SARIF result entry."
  @spec result_valid?(map()) :: boolean()
  def result_valid?(%{"ruleId" => ruleId, "level" => level, "message" => message})
      when is_binary(ruleId) and
             level in ["error", "warning", "note", "none"] do
    # message is an object with a "text" field per SARIF 2.1.0
    (is_map(message) and is_binary(Map.get(message, "text"))) or is_binary(message)
  end

  def result_valid?(_), do: false

  # ── Private: building results ──────────────────────────────────────────

  defp note_to_result(note) do
    rule_id = note.cve || note.key
    level = confidence_to_level(note.confidence)

    location = build_location(note)

    %{
      "ruleId" => rule_id,
      "level" => level,
      "message" => %{
        "text" => note.content || note.key
      },
      "locations" => [location],
      "partialFingerprints" => build_fingerprints(note),
      "properties" => %{
        "status" => Atom.to_string(note.status || :open),
        "confidence" => Atom.to_string(note.confidence || :medium),
        "target" => note.target,
        "cve" => note.cve,
        "noteKey" => note.key,
        "source" => note.source,
        "cvssScore" => note_cvss_score(note),
        "cwe" => note_cwe(note)
      }
    }
  end

  defp build_location(%{target: target, url: url}) when is_binary(target) do
    physical = %{
      "artifactLocation" => %{
        "uri" => url || target
      }
    }

    %{
      "physicalLocation" => physical,
      "logicalLocations" => [
        %{"name" => target}
      ]
    }
  end

  defp build_location(%{target: target}) when is_binary(target) do
    %{
      "physicalLocation" => %{
        "artifactLocation" => %{
          "uri" => target
        }
      },
      "logicalLocations" => [
        %{"name" => target}
      ]
    }
  end

  defp build_location(_), do: %{}

  defp build_fingerprints(note) do
    # partialFingerprints are used by SARIF consumers for deduplication.
    # A stable hash of target + cve + key gives a fingerprint that survives
    # across runs for the same finding.
    primary = "#{note.target}:#{note.cve}:#{note.key}"
    hash = :crypto.hash(:sha256, primary) |> Base.encode16(case: :lower)

    %{
      "primary" => hash,
      "target" => note.target || "",
      "cve" => note.cve || ""
    }
  end

  defp build_rules(vuln_notes) do
    vuln_notes
    |> Enum.uniq_by(fn n -> n.cve || n.key end)
    |> Enum.map(fn note ->
      %{
        "id" => note.cve || note.key,
        "name" => rule_name(note),
        "shortDescription" => %{
          "text" => String.slice(note.content || note.key, 0, 200)
        },
        "defaultConfiguration" => %{
          "level" => confidence_to_level(note.confidence)
        }
      }
    end)
  end

  defp rule_name(%{cve: cve}) when is_binary(cve), do: cve
  defp rule_name(%{key: key}), do: key

  defp confidence_to_level(:high), do: "error"
  defp confidence_to_level(:medium), do: "warning"
  defp confidence_to_level(:low), do: "note"
  defp confidence_to_level(_), do: "warning"

  # Prefer a computed CVSS base score (metadata or top-level) for SARIF
  # security-severity; fall back to nil so consumers can ignore it.
  defp note_cvss_score(note) do
    cond do
      is_number(Map.get(note, :cvss_score)) -> note.cvss_score
      is_number(get_in(note, [:metadata, :cvss_score])) -> note.metadata.cvss_score
      is_number(get_in(note, [:metadata, "cvss_score"])) -> note.metadata["cvss_score"]
      true -> nil
    end
  end

  defp note_cwe(note) do
    cond do
      is_binary(Map.get(note, :cwe)) -> note.cwe
      is_binary(get_in(note, [:metadata, :cwe])) -> note.metadata.cwe
      is_binary(get_in(note, [:metadata, "cwe"])) -> note.metadata["cwe"]
      true -> nil
    end
  end

  defp tool_version do
    case Application.spec(:optimal_system_agent, :vsn) do
      nil -> "dev"
      vsn -> List.to_string(vsn)
    end
  end

  defp default_path(session_id) do
    dir = Application.get_env(:optimal_system_agent, :sarif_dir, default_dir())
    safe = sanitize_session(session_id)
    Path.join(dir, "#{safe}.sarif.json")
  end

  defp default_dir do
    Path.join(System.user_home() || "/tmp", ".osa/sarif_reports")
  end

  defp sanitize_session(session_id) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, session_id) do
      session_id
    else
      :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    end
  end
end
