defmodule OptimalSystemAgent.Tools.Builtins.SecurityIntel do
  @moduledoc """
  Security intelligence tool — the agent-facing surface for the Tier 1
  intelligence layer.

  Exposes four capabilities to the agent during a security task:

    * **notes** — create, read, list, delete structured security notes
      (credentials, vulnerabilities, findings, artifacts, info). Schema-
      validated via `Security.StructuredNotes`.
    * **graph** — build the attack-surface knowledge graph from the
      session's notes and read strategic insights ("creds for X but
      unscanned", "lateral movement opportunity", etc.) via
      `Security.ShadowGraph`.
    * **tda** — Task Difficulty Assessment: given steps remaining,
      evidence confidence, context load, and historical success rate,
      returns an explore-vs-exploit recommendation via
      `Security.TaskDifficultyAssessment`.
    * **dedup** — check whether a candidate vulnerability finding is a
      duplicate of any in the session's existing findings (dependency-CVE
      fast path + structural comparison) via
      `Security.VulnDeduplication`.

  ## Availability

  Deferred: absent from the default toolbox, discovered mid-turn via
  `tool_search`. The intelligence layer is only relevant during a security
  task — loading its schema on every turn of every session is pure cost.
  `available?/0` returns true unconditionally; the SecurityContext prompt
  section is what tells the agent the tool exists and when to reach for it.

  ## State

  Notes are stored per-session in `Security.NotesStore` (ETS-backed
  GenServer). The store is started lazily on first `put` and torn down
  with the session.
  """

  use OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Security.{
    NotesStore,
    StructuredNotes,
    ShadowGraph,
    TaskDifficultyAssessment,
    VulnDeduplication,
    Playbook,
    SarifReport,
    CodeFix,
    ChainSummary,
    Cvss,
    CweCatalog,
    CallChainAnalyzer,
    RoeGuard,
    ReportGate,
    ThreatIntel,
    ReconIngest,
    AttackPath,
    AttackTaxonomy,
    VariantAnalysis,
    CiScan
  }

  alias OptimalSystemAgent.Tools.UseContext

  # Deferred — see moduledoc. The schema is only worth sending once a
  # security task is actually in flight, and `tool_search` is the gate.
  @impl true
  def should_defer?, do: true

  @impl true
  def name, do: "security_intel"

  @impl true
  def description do
    "Security intelligence layer for penetration testing: structured notes " <>
      "(credentials/vulnerabilities/findings), attack-surface knowledge graph " <>
      "with strategic insights, task difficulty assessment (explore vs exploit), " <>
      "and vulnerability deduplication. Use during security tasks to track " <>
      "engagement state and guide next steps."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => [
            "note_create",
            "note_get",
            "note_list",
            "note_delete",
            "note_count",
            "graph_insights",
            "graph_hosts",
            "graph_services",
            "tda",
            "dedup",
            "playbook_start",
            "playbook_current",
            "playbook_advance",
            "playbook_phases",
            "playbook_set_status",
            "sarif_generate",
            "codefix_record",
            "codefix_get",
            "codefix_list",
            "codefix_report",
            "summary_build",
            "summary_load",
            "whitebox_scan",
            "cvss_score",
            "cwe_lookup",
            "roe_check",
            "report_gate",
            "threat_lookup",
            "recon_ingest",
            "graph_attack_paths",
            "bloodhound_ingest",
            "variant_scan",
            "ci_scan",
            "map_technique",
            "coverage_report"
          ],
          "description" => "Intelligence action to perform"
        },
        "key" => %{
          "type" => "string",
          "description" => "Note key (for note_create, note_get, note_delete)"
        },
        "note" => %{
          "type" => "object",
          "description" =>
            "Note data for note_create. Required: category. " <>
              "credential needs username+target+password|protocol; " <>
              "vulnerability needs target+cve|weaknesses; " <>
              "finding needs target+services|endpoints|technologies|port; " <>
              "artifact needs target; info needs nothing.",
          "properties" => %{
            "category" => %{
              "type" => "string",
              "enum" => ["credential", "vulnerability", "finding", "artifact", "info"]
            },
            "content" => %{"type" => "string"},
            "target" => %{"type" => "string"},
            "source" => %{"type" => "string"},
            "username" => %{"type" => "string"},
            "password" => %{"type" => "string"},
            "protocol" => %{"type" => "string"},
            "port" => %{"type" => "string"},
            "cve" => %{"type" => "string"},
            "url" => %{"type" => "string"},
            "evidence_path" => %{"type" => "string"},
            "confidence" => %{
              "type" => "string",
              "enum" => ["high", "medium", "low"]
            },
            "status" => %{
              "type" => "string",
              "enum" => ["open", "closed", "filtered", "confirmed", "potential"]
            },
            "services" => %{"type" => "array"},
            "endpoints" => %{"type" => "array"},
            "technologies" => %{"type" => "array"},
            "weaknesses" => %{"type" => "array"}
          }
        },
        "category" => %{
          "type" => "string",
          "enum" => ["credential", "vulnerability", "finding", "artifact", "info"],
          "description" => "Filter for note_list / note_count"
        },
        "host_id" => %{
          "type" => "string",
          "description" => "Host node id (for graph_services), e.g. 'host:10.0.0.1'"
        },
        "steps_remaining" => %{
          "type" => "integer",
          "description" => "TDA: estimated steps remaining until task complete"
        },
        "evidence_confidence" => %{
          "type" => "number",
          "description" => "TDA: confidence in current finding (0.0-1.0)"
        },
        "context_load" => %{
          "type" => "number",
          "description" => "TDA: fraction of context window consumed (0.0-1.0)"
        },
        "historical_success_rate" => %{
          "type" => "number",
          "description" => "TDA: how often this approach type has worked (0.0-1.0)"
        },
        "task_type" => %{
          "type" => "string",
          "enum" => ["reconnaissance", "exploitation", "post_exploitation", "reporting"],
          "description" => "TDA: current phase"
        },
        "candidate" => %{
          "type" => "object",
          "description" => "dedup: candidate finding to check",
          "properties" => %{
            "id" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "target" => %{"type" => "string"},
            "endpoint" => %{"type" => "string"},
            "method" => %{"type" => "string"},
            "cve" => %{"type" => "string"},
            "dependency_metadata" => %{"type" => "object"}
          }
        },
        "playbook_id" => %{
          "type" => "string",
          "enum" => [
            "web_app",
            "network",
            "full_engagement",
            "whitebox",
            "ctf",
            "ci_scan",
            "cloud_engagement",
            "kubernetes",
            "active_directory"
          ],
          "description" => "playbook_start: which playbook to start"
        },
        "phase_status" => %{
          "type" => "string",
          "enum" => ["pending", "in_progress", "complete", "skipped"],
          "description" => "playbook_set_status: status to set on the current phase"
        },
        "fix" => %{
          "type" => "object",
          "description" => "codefix_record: a code fix to record for a finding",
          "properties" => %{
            "finding_key" => %{"type" => "string"},
            "file_path" => %{"type" => "string"},
            "fix_before" => %{"type" => "string"},
            "fix_after" => %{"type" => "string"},
            "language" => %{"type" => "string"},
            "explanation" => %{"type" => "string"}
          }
        },
        "whitebox" => %{
          "type" => "object",
          "description" =>
            "whitebox_scan: source-to-sink 0-day analysis of a source file. Provide the entry file's content; the analyzer traces tainted input to dangerous sinks and reports exploitable findings with CVSS.",
          "properties" => %{
            "entry" => %{"type" => "string", "description" => "path label of the entry file"},
            "content" => %{
              "type" => "string",
              "description" => "source of the entry file (required)"
            },
            "vuln_classes" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "subset of classes to hunt (default: all)"
            }
          }
        },
        "cvss_vector" => %{
          "type" => "string",
          "description" =>
            "cvss_score: a CVSS v3.1 base vector to score, e.g. CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
        },
        "vuln_class" => %{
          "type" => "string",
          "description" =>
            "cwe_lookup: a vuln class (sqli, idor, ssrf, xss, ...) to map to CWE/OWASP/typical CVSS"
        },
        "roe" => %{
          "type" => "object",
          "description" =>
            "roe_check: the rules-of-engagement contract to check an action against",
          "properties" => %{
            "targets" => %{"type" => "array", "items" => %{"type" => "string"}},
            "forbidden" => %{"type" => "array", "items" => %{"type" => "string"}},
            "max_blast" => %{"type" => "string"}
          }
        },
        "roe_action" => %{
          "type" => "object",
          "description" =>
            "roe_check: the proposed action — either a shell `command` (auto-classified) or an explicit `blast` class, plus a `target`",
          "properties" => %{
            "command" => %{"type" => "string"},
            "blast" => %{"type" => "string"},
            "target" => %{"type" => "string"}
          }
        },
        "finding" => %{
          "type" => "object",
          "description" => "report_gate / map_technique: a candidate finding to evaluate or tag"
        },
        "cve" => %{
          "type" => "string",
          "description" => "threat_lookup: CVE id (e.g. CVE-2021-44228)"
        },
        "tool" => %{
          "type" => "string",
          "description" => "recon_ingest: nmap | httpx | subfinder | nuclei | naabu"
        },
        "format" => %{
          "type" => "string",
          "description" => "recon_ingest: xml | jsonl | json | text"
        },
        "payload" => %{
          "type" => "string",
          "description" => "recon_ingest / bloodhound_ingest: raw tool output or JSON"
        },
        "from_id" => %{"type" => "string", "description" => "graph_attack_paths: source node id"},
        "to_id" => %{
          "type" => "string",
          "description" => "graph_attack_paths: destination node id"
        },
        "root" => %{"type" => "string", "description" => "variant_scan / ci_scan: workspace path"},
        "pattern" => %{"type" => "string", "description" => "variant_scan: literal or regex"},
        "needle" => %{"type" => "string", "description" => "variant_scan: seed snippet"},
        "technique_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "coverage_report: ATT&CK technique ids already tried"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def available?, do: true

  # Read-only by default; note_create/delete mutate session state but not the
  # filesystem, so they stay on the safe side of the taxonomy.
  @impl true
  def safety, do: :write_safe

  @impl true
  def read_only?(_input, _ctx), do: false
  @impl true
  def destructive?(_input, _ctx), do: false
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def execute(input, %UseContext{} = ctx) do
    session_id = ctx.session_id || "default"

    case Map.get(input, "action") do
      "note_create" -> do_note_create(session_id, input)
      "note_get" -> do_note_get(session_id, input)
      "note_list" -> do_note_list(session_id, input)
      "note_delete" -> do_note_delete(session_id, input)
      "note_count" -> do_note_count(session_id, input)
      "graph_insights" -> do_graph_insights(session_id)
      "graph_hosts" -> do_graph_hosts(session_id)
      "graph_services" -> do_graph_services(session_id, input)
      "tda" -> do_tda(input)
      "dedup" -> do_dedup(session_id, input)
      "playbook_start" -> do_playbook_start(session_id, input)
      "playbook_current" -> do_playbook_current(session_id)
      "playbook_advance" -> do_playbook_advance(session_id)
      "playbook_phases" -> do_playbook_phases(session_id)
      "playbook_set_status" -> do_playbook_set_status(session_id, input)
      "sarif_generate" -> do_sarif_generate(session_id, input)
      "codefix_record" -> do_codefix_record(session_id, input)
      "codefix_get" -> do_codefix_get(session_id, input)
      "codefix_list" -> do_codefix_list(session_id)
      "codefix_report" -> do_codefix_report(session_id)
      "summary_build" -> do_summary_build(session_id)
      "summary_load" -> do_summary_load(session_id)
      "whitebox_scan" -> do_whitebox_scan(session_id, input)
      "cvss_score" -> do_cvss_score(input)
      "cwe_lookup" -> do_cwe_lookup(input)
      "roe_check" -> do_roe_check(input)
      "report_gate" -> do_report_gate(input)
      "threat_lookup" -> do_threat_lookup(input)
      "recon_ingest" -> do_recon_ingest(session_id, input)
      "graph_attack_paths" -> do_graph_attack_paths(session_id, input)
      "bloodhound_ingest" -> do_bloodhound_ingest(session_id, input)
      "variant_scan" -> do_variant_scan(input)
      "ci_scan" -> do_ci_scan(input)
      "map_technique" -> do_map_technique(input)
      "coverage_report" -> do_coverage_report(input)
      nil -> {:error, "Missing required parameter: action"}
      other -> {:error, "Unknown action: #{other}"}
    end
  end

  # Flat-layout compat — empty context, no session.
  @impl true
  def execute(input), do: execute(input, UseContext.empty())

  # ── Notes ──────────────────────────────────────────────────────────────

  defp do_note_create(session_id, %{"key" => key, "note" => note_data}) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      data = normalize_note_data(note_data)

      case NotesStore.put(session_id, key, data) do
        {:ok, note} ->
          {:ok, format_note(note)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_note_create(_session_id, _input) do
    {:error, "note_create requires 'key' and 'note' parameters"}
  end

  defp do_note_get(session_id, %{"key" => key}) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      case NotesStore.get(session_id, key) do
        {:ok, note} -> {:ok, format_note(note)}
        :not_found -> {:ok, "No note with key '#{key}'."}
      end
    end
  end

  defp do_note_get(_session_id, _input), do: {:error, "note_get requires 'key'"}

  defp do_note_list(session_id, input) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      category = input |> Map.get("category") |> to_category_atom()
      notes = NotesStore.list(session_id, category)

      if notes == [] do
        {:ok, "No notes stored#{category_suffix(category)}."}
      else
        body =
          notes
          |> Enum.map(&format_note/1)
          |> Enum.join("\n\n")

        {:ok, "#{length(notes)} note(s)#{category_suffix(category)}:\n\n#{body}"}
      end
    end
  end

  defp do_note_delete(session_id, %{"key" => key}) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      case NotesStore.delete(session_id, key) do
        :ok -> {:ok, "Note '#{key}' deleted."}
        :not_found -> {:ok, "No note with key '#{key}' — nothing to delete."}
      end
    end
  end

  defp do_note_delete(_session_id, _input), do: {:error, "note_delete requires 'key'"}

  defp do_note_count(session_id, input) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      category = input |> Map.get("category") |> to_category_atom()
      count = NotesStore.count(session_id, category)
      {:ok, "#{count} note(s)#{category_suffix(category)}"}
    end
  end

  # ── Graph ───────────────────────────────────────────────────────────────

  defp do_graph_insights(session_id) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      graph = NotesStore.graph(session_id)
      insights = ShadowGraph.strategic_insights(graph)

      if insights == [] do
        hosts = ShadowGraph.hosts(graph)

        if hosts == [] do
          {:ok,
           "No strategic insights yet — the graph is empty. Add notes " <>
             "(credentials, findings, vulnerabilities) to build the attack surface."}
        else
          {:ok,
           "No strategic insights yet — #{length(hosts)} host(s) in the graph " <>
             "but no actionable patterns (e.g. creds-without-scan, confirmed-vulns)."}
        end
      else
        body = insights |> Enum.map(fn s -> "  • #{s}" end) |> Enum.join("\n")
        {:ok, "#{length(insights)} strategic insight(s):\n#{body}"}
      end
    end
  end

  defp do_graph_hosts(session_id) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      graph = NotesStore.graph(session_id)
      hosts = ShadowGraph.hosts(graph)

      if hosts == [] do
        {:ok, "No hosts in the graph yet. Add notes with target fields to populate it."}
      else
        body =
          hosts
          |> Enum.map(fn h -> "  • #{h.label} (#{h.id})" end)
          |> Enum.join("\n")

        {:ok, "#{length(hosts)} host(s):\n#{body}"}
      end
    end
  end

  defp do_graph_services(session_id, %{"host_id" => host_id}) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      graph = NotesStore.graph(session_id)

      # Accept both "host:10.0.0.1" and "10.0.0.1"
      full_id = if String.starts_with?(host_id, "host:"), do: host_id, else: "host:#{host_id}"

      services = ShadowGraph.services_for_host(graph, full_id)

      if services == [] do
        {:ok, "No services found for #{full_id}."}
      else
        body =
          services
          |> Enum.map(fn s -> "  • #{s.label}" end)
          |> Enum.join("\n")

        {:ok, "#{length(services)} service(s) on #{full_id}:\n#{body}"}
      end
    end
  end

  defp do_graph_services(_session_id, _input),
    do: {:error, "graph_services requires 'host_id'"}

  # ── TDA ─────────────────────────────────────────────────────────────────

  defp do_whitebox_scan(session_id, input) do
    wb = Map.get(input, "whitebox", %{})
    content = Map.get(wb, "content")

    classes =
      case Map.get(wb, "vuln_classes") do
        list when is_list(list) and list != [] ->
          Enum.map(list, &safe_atom/1) |> Enum.filter(&(&1 in CallChainAnalyzer.vuln_classes()))

        _ ->
          CallChainAnalyzer.vuln_classes()
      end

    opts = [
      entry: Map.get(wb, "entry", "<entry>"),
      content: content,
      vuln_classes: classes
    ]

    case CallChainAnalyzer.analyze(opts) do
      {:ok, []} ->
        {:ok,
         "Whitebox scan complete: no exploitable source-to-sink chains found in the provided file."}

      {:ok, findings} ->
        # Record each exploitable finding as a vulnerability note so it flows
        # into the graph, dedup, and SARIF report like any other finding.
        Enum.each(findings, fn f -> record_whitebox_finding(session_id, f) end)

        body =
          findings
          |> Enum.map(&format_whitebox_finding/1)
          |> Enum.join("\n\n")

        {:ok, "Whitebox scan found #{length(findings)} exploitable chain(s):\n\n" <> body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_whitebox_finding(session_id, f) do
    # `:vulnerability` notes require a non-empty target and at least one of
    # cve/weaknesses. Guarantee both: fall back to the CWE id, then to the
    # class label, so a finding always records even when the judge left the
    # sink blank or the class has no catalogued CWE.
    weaknesses =
      [CweCatalog.cwe(f.vuln_class), to_string(f.vuln_class)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    target = if f.sink in [nil, ""], do: to_string(f.vuln_class), else: f.sink

    # Stable key from class+source+sink so re-scanning the same chain replaces
    # rather than duplicates the note (cheap dedup for repeated whitebox runs).
    digest =
      :crypto.hash(:sha256, "#{f.vuln_class}|#{f.source}|#{f.sink}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    key = "whitebox:#{f.vuln_class}:#{digest}"

    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      NotesStore.put(session_id, key, %{
        category: :vulnerability,
        content: "#{f.vuln_class}: #{f.reasoning}",
        confidence: f.confidence,
        status: :potential,
        target: target,
        source: f.source,
        weaknesses: weaknesses,
        metadata: %{
          vuln_class: to_string(f.vuln_class),
          call_chain: f.call_chain,
          poc: f.poc,
          cvss_vector: f.cvss_vector,
          cvss_score: f.cvss_score,
          severity: f.severity && to_string(f.severity)
        }
      })
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp format_whitebox_finding(f) do
    score = if f.cvss_score, do: " (CVSS #{f.cvss_score} #{f.severity})", else: ""

    """
    [#{f.vuln_class}]#{score} confidence=#{f.confidence}
      source: #{f.source}
      sink:   #{f.sink}
      chain:  #{Enum.join(f.call_chain, " -> ")}
      why:    #{f.reasoning}
      poc:    #{f.poc}
    """
  end

  defp do_cvss_score(input) do
    case Cvss.score(Map.get(input, "cvss_vector", "")) do
      {:ok, %{base_score: score, severity: sev, vector: v}} ->
        {:ok, "CVSS #{score} (#{sev})\nvector: #{v}"}

      {:error, reason} ->
        {:error, "Invalid CVSS vector: #{reason}"}
    end
  end

  defp do_cwe_lookup(input) do
    class = input |> Map.get("vuln_class", "") |> safe_atom()

    case CweCatalog.lookup(class) do
      %{cwe: cwe, name: name, owasp: owasp, typical_cvss: vector} ->
        {:ok, "#{cwe} #{name}\nOWASP: #{owasp}\nTypical CVSS: #{vector}"}

      _ ->
        {:error,
         "No CWE mapping for #{inspect(class)}. Known: #{CweCatalog.classes() |> Enum.map_join(", ", &to_string/1)}"}
    end
  end

  defp do_roe_check(input) do
    contract = parse_roe_contract(Map.get(input, "roe"))
    action = parse_roe_action(Map.get(input, "roe_action", %{}))

    {verdict, reason} = RoeGuard.check(contract, action)

    {:ok,
     "RoE verdict: #{verdict}\nblast: #{action.blast}\ntarget: #{action[:target] || "-"}\nreason: #{reason}"}
  end

  defp do_report_gate(input) do
    finding = Map.get(input, "finding") || %{}

    case ReportGate.evaluate(finding) do
      {:ok, f} ->
        {:ok, "eligible\nCWE #{f.cwe}\nOWASP #{f.owasp}\nCVSS #{f.cvss_score} (#{f.severity})"}

      {:error, reasons} ->
        {:error, "not report-grade: " <> Enum.join(reasons, "; ")}
    end
  end

  defp do_threat_lookup(input) do
    cve = Map.get(input, "cve") || get_in(input, ["finding", "cve"])

    case cve && ThreatIntel.lookup(cve) do
      {:ok, entry} ->
        {:ok,
         "#{entry["cve"]} KEV=true #{entry["shortName"]} (#{entry["vendor"]} #{entry["product"]})"}

      :not_found ->
        {:ok, "#{cve} is not on the bundled KEV list"}

      _ ->
        {:error, "threat_lookup requires 'cve'"}
    end
  end

  defp do_recon_ingest(session_id, input) do
    case ReconIngest.ingest(input) do
      {:ok, []} ->
        {:ok, "recon_ingest: no records"}

      {:ok, notes} ->
        with {:ok, _} <- NotesStore.ensure_started(session_id) do
          notes
          |> Enum.with_index(1)
          |> Enum.each(fn {note, i} ->
            key = "recon:#{note.source}:#{i}:#{note.target}"
            NotesStore.put(session_id, key, note)
          end)
        end

        {:ok, "ingested #{length(notes)} note(s) from #{Map.get(input, "tool")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_graph_attack_paths(session_id, input) do
    graph = session_graph(session_id)
    from_id = Map.get(input, "from_id")
    to_id = Map.get(input, "to_id")

    cond do
      is_binary(from_id) and is_binary(to_id) ->
        case AttackPath.shortest_path(graph, from_id, to_id) do
          {:ok, path} ->
            {:ok, "cost #{path.cost}: " <> Enum.join(path.nodes, " -> ")}

          :unreachable ->
            {:ok, "no path from #{from_id} to #{to_id}"}

          {:error, reason} ->
            {:error, reason}
        end

      is_binary(from_id) ->
        paths = AttackPath.paths_from(graph, from_id, limit: 10)

        body =
          paths
          |> Enum.map(fn p -> "  #{p.cost}  #{Enum.join(p.nodes, " -> ")}" end)
          |> Enum.join("\n")

        {:ok, if(body == "", do: "no paths from #{from_id}", else: "paths:\n#{body}")}

      true ->
        {:error, "graph_attack_paths requires 'from_id'"}
    end
  end

  defp do_bloodhound_ingest(session_id, input) do
    payload = Map.get(input, "payload") || ""
    base = session_graph(session_id)

    case AttackPath.ingest_bloodhound(base, payload) do
      {:ok, graph} ->
        AttackPath.store(session_id, graph)
        {:ok, "ingested #{map_size(graph.nodes)} node(s), #{length(graph.edges)} edge(s)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_graph(session_id) do
    stored = AttackPath.fetch(session_id)

    if stored.edges == [] and stored.nodes == %{} do
      case NotesStore.ensure_started(session_id) do
        {:ok, _} -> NotesStore.graph(session_id)
        _ -> AttackPath.new()
      end
    else
      stored
    end
  rescue
    _ -> AttackPath.fetch(session_id)
  end

  defp do_variant_scan(input) do
    opts =
      [root: Map.get(input, "root")]
      |> maybe_kw(:pattern, Map.get(input, "pattern"))
      |> maybe_kw(:needle, Map.get(input, "needle"))

    case VariantAnalysis.scan(opts) do
      {:ok, []} ->
        {:ok, "variant_scan: no hits"}

      {:ok, hits} ->
        body =
          hits
          |> Enum.take(30)
          |> Enum.map(fn h -> "  #{h.path}:#{h.line}  #{h.fingerprint}  #{h.snippet}" end)
          |> Enum.join("\n")

        {:ok, "#{length(hits)} hit(s):\n#{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_ci_scan(input) do
    root = Map.get(input, "root") || File.cwd!()

    case CiScan.run(root: root) do
      {:ok, report} ->
        s = report.summary

        {:ok,
         "ci_scan entries=#{report.entries_scanned} failed=#{report.failed?} " <>
           "critical=#{s.critical} high=#{s.high} medium=#{s.medium} low=#{s.low}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_map_technique(input) do
    class = Map.get(input, "vuln_class")
    finding = Map.get(input, "finding")

    tag =
      cond do
        is_map(finding) -> AttackTaxonomy.tag(finding)
        is_binary(class) -> AttackTaxonomy.tag(safe_atom(class))
        true -> nil
      end

    case tag do
      %{technique_id: id, name: name, tactic: tactic} ->
        {:ok, "#{id} #{name} (#{tactic})"}

      _ ->
        {:error, "no ATT&CK mapping"}
    end
  end

  defp do_coverage_report(input) do
    ids = Map.get(input, "technique_ids") || []
    report = AttackTaxonomy.coverage_report(ids)

    {:ok,
     "tried #{length(report.tried)} / #{length(report.tried) + length(report.untried)}\n" <>
       "tactics covered: #{Enum.map_join(report.tactics_covered, ", ", &to_string/1)}\n" <>
       "tactics missing: #{Enum.map_join(report.tactics_missing, ", ", &to_string/1)}"}
  end

  defp maybe_kw(opts, _k, nil), do: opts
  defp maybe_kw(opts, _k, ""), do: opts
  defp maybe_kw(opts, k, v), do: Keyword.put(opts, k, v)

  defp parse_roe_contract(nil), do: nil

  defp parse_roe_contract(%{} = roe) do
    %{
      targets: Map.get(roe, "targets", []),
      forbidden: roe |> Map.get("forbidden", []) |> Enum.map(&safe_atom/1),
      max_blast: roe |> Map.get("max_blast") |> safe_atom_or_nil()
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_roe_action(%{} = a) do
    blast =
      case Map.get(a, "blast") do
        b when is_binary(b) and b != "" -> safe_atom(b)
        _ -> a |> Map.get("command", "") |> RoeGuard.classify()
      end

    %{blast: blast, target: Map.get(a, "target")}
  end

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :unknown
  end

  defp safe_atom(a) when is_atom(a), do: a
  defp safe_atom(_), do: :unknown

  defp safe_atom_or_nil(nil), do: nil
  defp safe_atom_or_nil(s), do: safe_atom(s)

  defp do_tda(input) do
    opts = %{
      steps_remaining: Map.get(input, "steps_remaining", 10),
      evidence_confidence: Map.get(input, "evidence_confidence", 0.5),
      context_load: Map.get(input, "context_load", 0.5),
      historical_success_rate: Map.get(input, "historical_success_rate", 0.5),
      task_type: input |> Map.get("task_type", "exploitation") |> to_task_type()
    }

    case TaskDifficultyAssessment.assess(opts) do
      {:ok, assessment} ->
        body = """
        Decision: #{assessment.decision}
        Confidence: #{assessment.confidence}
        Reasoning: #{assessment.reasoning}

        Scores:
          horizon:       #{Float.round(assessment.scores.horizon, 2)}
          confidence:    #{Float.round(assessment.scores.confidence, 2)}
          context_load:  #{Float.round(assessment.scores.context_load, 2)}
          success_rate:  #{Float.round(assessment.scores.success_rate, 2)}
        """

        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Dedup ───────────────────────────────────────────────────────────────

  defp do_dedup(session_id, %{"candidate" => candidate}) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      # Existing findings are the session's vulnerability + finding notes,
      # reshaped into the finding map the dedup module expects.
      existing =
        NotesStore.list(session_id)
        |> Enum.filter(&(&1.category in [:vulnerability, :finding]))
        |> Enum.map(&note_to_finding/1)

      normalized = normalize_finding(candidate)

      case VulnDeduplication.check(normalized, existing) do
        {:ok, result} ->
          if result.is_duplicate do
            {:ok,
             "DUPLICATE of #{result.duplicate_id} (confidence #{result.confidence}). " <>
               "Reason: #{result.reason}"}
          else
            {:ok,
             "NOT a duplicate (confidence #{result.confidence}). " <>
               "Reason: #{result.reason}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_dedup(_session_id, _input),
    do: {:error, "dedup requires 'candidate' parameter"}

  # ── Playbook ────────────────────────────────────────────────────────────

  defp do_playbook_start(session_id, %{"playbook_id" => pb_id}) do
    pb_atom = if is_binary(pb_id), do: String.to_atom(pb_id), else: pb_id

    case Playbook.start(session_id, pb_atom) do
      {:ok, pb} ->
        {:ok, phase} = Playbook.current(session_id)

        {:ok,
         "Started playbook '#{pb.name}' (#{length(pb.phases)} phases).\n\n" <>
           Playbook.render_phase(phase)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_playbook_start(_session_id, _input),
    do:
      {:error,
       "playbook_start requires 'playbook_id' (web_app, network, full_engagement, whitebox, ctf, ci_scan, cloud_engagement, kubernetes, active_directory)"}

  defp do_playbook_current(session_id) do
    case Playbook.current(session_id) do
      {:ok, phase} -> {:ok, Playbook.render_phase(phase)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_playbook_advance(session_id) do
    case Playbook.advance(session_id) do
      {:ok, phase} ->
        {:ok,
         "Advanced to phase #{phase.index + 1}: #{phase.name}\n\n" <> Playbook.render_phase(phase)}

      :complete ->
        {:ok, "Playbook complete — all phases finished."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_playbook_phases(session_id) do
    case Playbook.phases(session_id) do
      {:ok, phases} ->
        body =
          phases
          |> Enum.map(fn p -> "  #{p.index + 1}. [#{p.status}] #{p.name}" end)
          |> Enum.join("\n")

        {:ok, "Phases:\n#{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_playbook_set_status(session_id, %{"phase_status" => status}) do
    status_atom = if is_binary(status), do: String.to_atom(status), else: status

    case Playbook.set_status(session_id, status_atom) do
      :ok -> {:ok, "Phase status set to #{status_atom}."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_playbook_set_status(_session_id, _input),
    do: {:error, "playbook_set_status requires 'phase_status'"}

  # ── SARIF ───────────────────────────────────────────────────────────────

  defp do_sarif_generate(session_id, input) do
    to_file = Map.get(input, "to_file", false)

    case SarifReport.generate(session_id, to_file: to_file) do
      {:ok, %{report: report, path: path}} ->
        {:ok,
         "SARIF report written to #{path}. #{length(report["runs"] |> hd() |> Map.get("results", []))} result(s)."}

      {:ok, report} ->
        results = report["runs"] |> hd() |> Map.get("results", [])

        {:ok,
         "SARIF report generated (#{length(results)} result(s)). Use to_file=true to write to disk."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── CodeFix ────────────────────────────────────────────────────────────

  defp do_codefix_record(session_id, %{"fix" => fix}) do
    case CodeFix.record(session_id, fix) do
      {:ok, fix} ->
        {:ok, "Code fix recorded for finding '#{fix.finding_key}' on #{fix.file_path}."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_codefix_record(_session_id, _input),
    do: {:error, "codefix_record requires 'fix' parameter"}

  defp do_codefix_get(session_id, %{"key" => finding_key}) do
    case CodeFix.get(session_id, finding_key) do
      {:ok, fix} -> {:ok, CodeFix.render_diff(fix)}
      :not_found -> {:ok, "No code fix recorded for finding '#{finding_key}'."}
    end
  end

  defp do_codefix_get(_session_id, _input),
    do: {:error, "codefix_get requires 'key' (finding key)"}

  defp do_codefix_list(session_id) do
    case CodeFix.list(session_id) do
      {:ok, []} ->
        {:ok, "No code fixes recorded."}

      {:ok, fixes} ->
        body = Enum.map_join(fixes, "\n", fn f -> "  • #{f.finding_key} — #{f.file_path}" end)
        {:ok, "#{length(fixes)} code fix(es):\n#{body}"}
    end
  end

  defp do_codefix_report(session_id) do
    CodeFix.render_report(session_id)
  end

  # ── ChainSummary ────────────────────────────────────────────────────────

  defp do_summary_build(session_id) do
    with {:ok, _} <- NotesStore.ensure_started(session_id) do
      notes = NotesStore.list(session_id)
      graph = NotesStore.graph(session_id)

      phase =
        case Playbook.current(session_id) do
          {:ok, p} -> Map.take(p, [:name, :status, :entry_criteria, :exit_criteria])
          _ -> nil
        end

      summary = ChainSummary.build(session_id, notes: notes, graph: graph, phase: phase)
      ChainSummary.save(session_id, summary)
      {:ok, ChainSummary.render(summary)}
    end
  end

  defp do_summary_load(session_id) do
    case ChainSummary.load(session_id) do
      {:ok, summary} -> {:ok, ChainSummary.render(summary)}
      {:error, _} -> {:ok, "No saved summary for this session. Call summary_build first."}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp normalize_note_data(data) when is_map(data) do
    # JSON arrives as string keys; StructuredNotes expects atom keys.
    # The `category` value must also be an atom (validate/1 pattern-matches
    # on `category in @categories`, which are atoms).
    data
    |> Enum.map(fn
      {"category", v} when is_binary(v) -> {:category, String.to_atom(v)}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp to_category_atom(nil), do: nil
  defp to_category_atom(s) when is_binary(s), do: String.to_atom(s)
  defp to_category_atom(a) when is_atom(a), do: a

  defp to_task_type(nil), do: :exploitation
  defp to_task_type(s) when is_binary(s), do: String.to_atom(s)
  defp to_task_type(a) when is_atom(a), do: a

  defp category_suffix(nil), do: ""
  defp category_suffix(c), do: " (category: #{c})"

  defp format_note(note) do
    lines = [
      "key: #{note.key}",
      "category: #{note.category}",
      "content: #{note.content || "(none)"}"
    ]

    lines =
      (lines ++
         [
           note.target && "target: #{note.target}",
           note.source && "source: #{note.source}",
           note.username && "username: #{note.username}",
           note.protocol && "protocol: #{note.protocol}",
           note.port && "port: #{note.port}",
           note.cve && "cve: #{note.cve}",
           note.url && "url: #{note.url}",
           note.evidence_path && "evidence_path: #{note.evidence_path}",
           note.confidence && "confidence: #{note.confidence}",
           note.status && "status: #{note.status}"
         ])
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\n")
  end

  defp note_to_finding(note) do
    %{
      id: note.key,
      title: note.content || "",
      description: note.content || "",
      target: note.target,
      endpoint: note.url,
      method: nil,
      technical_analysis: nil,
      poc_description: nil,
      impact: nil,
      cve: note.cve,
      dependency_metadata: nil
    }
  end

  defp normalize_finding(f) when is_map(f) do
    f
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end
end
