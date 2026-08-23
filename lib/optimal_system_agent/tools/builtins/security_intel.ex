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
    VulnDeduplication
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
            "dedup"
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
