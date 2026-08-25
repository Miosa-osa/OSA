defmodule OptimalSystemAgent.Security.ChainSummary do
  @moduledoc """
  Chain summarization for pentest engagement state (Tier 2 #8).

  Adapted from PentAGI's chain-summarization pattern. As a security engagement
  grows long, the raw note set + graph + conversation history outgrow the
  context window. This module produces a compact, structured running summary
  of the engagement state that can be injected into context in place of the
  full history — preserving the strategic picture (hosts found, creds obtained,
  vulns confirmed, phases completed, open questions) while shedding the raw
  tool output that produced them.

  ## What it summarizes

  - **Notes** — grouped by category, counted, with the highest-confidence
    credential and vulnerability notes surfaced verbatim (those are the ones
    a continuation agent most needs).
  - **Graph** — host count, service count, credential-to-host edges, and the
    ShadowGraph strategic insights (which are already a compressed form).
  - **Phase** — the current playbook phase and its entry/exit status, if a
    playbook is active (see `Security.Playbook`).
  - **Open questions** — `:info` notes with a `question` marker in metadata
    are surfaced as an explicit todo list.

  ## Persistence

  Summaries are written to a per-session file under the OSA data dir so a
  resumed session can re-inject the last summary without re-reading the full
  transcript. `load/1` reads the most recent; `save/2` overwrites.

  ## Usage

      summary = ChainSummary.build(session_id, notes: notes, graph: graph)
      ChainSummary.save(session_id, summary)
      {:ok, summary} = ChainSummary.load(session_id)
      text = ChainSummary.render(summary)
  """

  require Logger

  alias OptimalSystemAgent.Security.ShadowGraph

  @type summary :: %{
          session_id: String.t(),
          built_at: DateTime.t(),
          counts: %{atom() => non_neg_integer()},
          total_notes: non_neg_integer(),
          hosts: [map()],
          services_count: non_neg_integer(),
          top_credential: map() | nil,
          top_vulnerability: map() | nil,
          insights: [String.t()],
          open_questions: [String.t()],
          phase: map() | nil,
          token_budget_hint: non_neg_integer()
        }

  @doc "Build a summary from the session's notes and graph."
  @spec build(String.t(), keyword()) :: summary()
  def build(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    notes = Keyword.get(opts, :notes, [])
    graph = Keyword.get(opts, :graph, ShadowGraph.new())
    phase = Keyword.get(opts, :phase)

    counts = count_by_category(notes)
    hosts = ShadowGraph.hosts(graph)
    services_count = count_services(graph)
    top_credential = top_note(notes, :credential)
    top_vulnerability = top_note(notes, :vulnerability)
    insights = ShadowGraph.strategic_insights(graph)
    open_questions = extract_questions(notes)

    %{
      session_id: session_id,
      built_at: DateTime.utc_now(),
      counts: counts,
      total_notes: length(notes),
      hosts: hosts,
      services_count: services_count,
      top_credential: top_credential,
      top_vulnerability: top_vulnerability,
      insights: insights,
      open_questions: open_questions,
      phase: phase,
      # Rough hint: a summary targets ~1.5k tokens. The renderer stays well
      # under this; the field lets a caller decide whether to also include
      # the full note set.
      token_budget_hint: 1_500
    }
  end

  @doc "Render a summary as a compact text block suitable for prompt injection."
  @spec render(summary()) :: String.t()
  def render(%{} = summary) do
    lines = ["<engagement_summary>"]

    lines =
      lines ++
        [
          "Built: #{format_dt(summary.built_at)}",
          "Notes: #{summary.total_notes} total " <>
            "(credential: #{summary.counts[:credential] || 0}, " <>
            "vulnerability: #{summary.counts[:vulnerability] || 0}, " <>
            "finding: #{summary.counts[:finding] || 0}, " <>
            "artifact: #{summary.counts[:artifact] || 0}, " <>
            "info: #{summary.counts[:info] || 0})"
        ]

    lines =
      if summary.hosts != [] do
        host_labels = Enum.map_join(summary.hosts, ", ", & &1.label)
        lines ++ ["Hosts (#{length(summary.hosts)}): #{host_labels}"]
      else
        lines ++ ["Hosts: none discovered yet"]
      end

    lines =
      lines ++ ["Services discovered: #{summary.services_count}"]

    lines =
      if summary.top_credential do
        lines ++
          [
            "Top credential: #{summary.top_credential.username}@#{summary.top_credential.target}" <>
              " (#{summary.top_credential.protocol || "password"})"
          ]
      else
        lines ++ ["Top credential: none"]
      end

    lines =
      if summary.top_vulnerability do
        lines ++
          [
            "Top vulnerability: #{summary.top_vulnerability.cve || "no CVE"} " <>
              "on #{summary.top_vulnerability.target} (#{summary.top_vulnerability.confidence})"
          ]
      else
        lines ++ ["Top vulnerability: none"]
      end

    lines =
      if summary.phase do
        lines ++
          [
            "Phase: #{summary.phase.name} (#{summary.phase.status})" <>
              if(summary.phase.exit_criteria && summary.phase.exit_criteria != [],
                do: " — exit criteria: #{Enum.join(summary.phase.exit_criteria, "; ")}",
                else: ""
              )
          ]
      else
        lines
      end

    lines =
      if summary.insights != [] do
        insight_lines =
          summary.insights
          |> Enum.map(fn s -> "  - #{s}" end)

        lines ++ ["Strategic insights:"] ++ insight_lines
      else
        lines
      end

    lines =
      if summary.open_questions != [] do
        q_lines =
          summary.open_questions
          |> Enum.map(fn q -> "  - #{q}" end)

        lines ++ ["Open questions:"] ++ q_lines
      else
        lines
      end

    lines = lines ++ ["</engagement_summary>"]

    Enum.join(lines, "\n")
  end

  @doc "Save the summary to the per-session summary file."
  @spec save(String.t(), summary()) :: :ok | {:error, term()}
  def save(session_id, %{} = summary) when is_binary(session_id) do
    path = summary_path(session_id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      data = summary_to_json(summary)
      File.write(path, data)
    end
  end

  @doc "Load the most recent summary for a session."
  @spec load(String.t()) :: {:ok, summary()} | {:error, term()}
  def load(session_id) when is_binary(session_id) do
    path = summary_path(session_id)

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} -> {:ok, summary_from_json(map)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Delete the summary file for a session."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    path = summary_path(session_id)
    File.rm(path)
    :ok
  end

  @doc "Path to the per-session summary file."
  @spec summary_path(String.t()) :: String.t()
  def summary_path(session_id) do
    dir = Application.get_env(:optimal_system_agent, :chain_summary_dir, default_dir())
    safe = sanitize_session(session_id)
    Path.join(dir, "#{safe}.json")
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp default_dir do
    Path.join(System.user_home() || "/tmp", ".osa/chain_summaries")
  end

  # The session id is turned into a filename. Reject path traversal spellings
  # the same way the checkpoint module does — a `..` or `/` in the id must not
  # escape the summary directory.
  defp sanitize_session(session_id) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, session_id) do
      session_id
    else
      # Hash non-conforming ids so they're still unique but can't traverse.
      :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    end
  end

  defp count_by_category(notes) do
    notes
    |> Enum.reduce(%{}, fn note, acc ->
      Map.update(acc, note.category, 1, &(&1 + 1))
    end)
  end

  defp count_services(graph) do
    length(ShadowGraph.nodes_of_type(graph, "service"))
  end

  # The "top" note is the highest-confidence one in the category. Confidence
  # ordering: high > medium > low.
  defp top_note(notes, category) do
    notes
    |> Enum.filter(&(&1.category == category))
    |> Enum.sort_by(&confidence_rank/1, &>=/2)
    |> List.first()
  end

  defp confidence_rank(%{confidence: :high}), do: 3
  defp confidence_rank(%{confidence: :medium}), do: 2
  defp confidence_rank(_), do: 1

  defp extract_questions(notes) do
    notes
    |> Enum.filter(fn n -> n.category == :info end)
    |> Enum.filter(fn n ->
      match?(%{metadata: %{"question" => _}}, n) or match?(%{metadata: %{question: _}}, n)
    end)
    |> Enum.map(fn n ->
      Map.get(n.metadata, "question") || Map.get(n.metadata, :question) || n.content
    end)
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(s) when is_binary(s), do: s

  # ── JSON serialization ──────────────────────────────────────────────────

  defp summary_to_json(summary) do
    Jason.encode!(
      %{
        session_id: summary.session_id,
        built_at: DateTime.to_iso8601(summary.built_at),
        counts: for({k, v} <- summary.counts, into: %{}, do: {to_string(k), v}),
        total_notes: summary.total_notes,
        hosts: Enum.map(summary.hosts, &Map.take(&1, [:id, :label, :type])),
        services_count: summary.services_count,
        top_credential: note_to_json(summary.top_credential),
        top_vulnerability: note_to_json(summary.top_vulnerability),
        insights: summary.insights,
        open_questions: summary.open_questions,
        phase: phase_to_json(summary.phase),
        token_budget_hint: summary.token_budget_hint
      },
      pretty: true
    )
  end

  defp note_to_json(nil), do: nil

  defp note_to_json(note) do
    Map.take(note, [
      :key,
      :category,
      :content,
      :target,
      :username,
      :protocol,
      :cve,
      :confidence,
      :status
    ])
  end

  defp phase_to_json(nil), do: nil

  defp phase_to_json(phase) do
    Map.take(phase, [:name, :status, :entry_criteria, :exit_criteria])
  end

  defp summary_from_json(map) do
    %{
      session_id: map["session_id"],
      built_at: parse_dt(map["built_at"]),
      counts: for({k, v} <- map["counts"] || %{}, do: {String.to_atom(k), v}) |> Map.new(),
      total_notes: map["total_notes"],
      hosts: map["hosts"] || [],
      services_count: map["services_count"],
      top_credential: note_from_json(map["top_credential"]),
      top_vulnerability: note_from_json(map["top_vulnerability"]),
      insights: map["insights"] || [],
      open_questions: map["open_questions"] || [],
      phase: phase_from_json(map["phase"]),
      token_budget_hint: map["token_budget_hint"] || 1_500
    }
  end

  defp note_from_json(nil), do: nil

  defp note_from_json(map) do
    %{
      key: map["key"],
      category: String.to_atom(map["category"] || "info"),
      content: map["content"],
      target: map["target"],
      username: map["username"],
      protocol: map["protocol"],
      cve: map["cve"],
      confidence: atomize_confidence(map["confidence"]),
      status: atomize_status(map["status"])
    }
  end

  defp phase_from_json(nil), do: nil

  defp phase_from_json(map) do
    %{
      name: map["name"],
      status: String.to_atom(map["status"] || "pending"),
      entry_criteria: map["entry_criteria"] || [],
      exit_criteria: map["exit_criteria"] || []
    }
  end

  defp atomize_confidence(nil), do: :medium
  defp atomize_confidence(s) when is_binary(s), do: String.to_atom(s)
  defp atomize_confidence(a) when is_atom(a), do: a

  defp atomize_status(nil), do: :open
  defp atomize_status(s) when is_binary(s), do: String.to_atom(s)
  defp atomize_status(a) when is_atom(a), do: a

  defp parse_dt(nil), do: DateTime.utc_now()

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
