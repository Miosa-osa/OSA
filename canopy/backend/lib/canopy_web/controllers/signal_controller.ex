defmodule CanopyWeb.SignalController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.ActivityEvent
  import Ecto.Query

  # Signal Theory: S = (M, G, T, F, W)
  # M = Mode (Linguistic, Visual, Code)
  # G = Genre (Spec, Report, PR, ADR, Brief, etc.)
  # T = Type (Direct, Inform, Commit, Decide, Express)
  # F = Format (Markdown, code file, CLI output, diff)
  # W = Structure (genre-specific template/skeleton)

  def classify(conn, params) do
    message = params["message"] || ""

    classification = classify_signal(message)
    json(conn, %{classification: classification, message: message})
  end

  def feed(conn, params) do
    workspace_id = params["workspace_id"]
    limit = min(String.to_integer(params["limit"] || "20"), 100)

    query =
      from e in ActivityEvent,
        where: e.level in ["warn", "error"],
        order_by: [desc: e.inserted_at],
        limit: ^limit

    query = if workspace_id, do: where(query, [e], e.workspace_id == ^workspace_id), else: query

    events = Repo.all(query)

    signals =
      Enum.map(events, fn e ->
        %{
          id: e.id,
          event_type: e.event_type,
          message: e.message,
          level: e.level,
          workspace_id: e.workspace_id,
          agent_id: e.agent_id,
          inserted_at: e.inserted_at,
          signal_type: level_to_signal_type(e.level)
        }
      end)

    json(conn, %{signals: signals})
  end

  def patterns(conn, _params) do
    # Placeholder — future: mine ActivityEvent for recurring patterns
    json(conn, %{
      patterns: [],
      note: "Pattern analysis not yet implemented"
    })
  end

  def stats(conn, params) do
    workspace_id = params["workspace_id"]

    base_query = from e in ActivityEvent
    base_query = if workspace_id, do: where(base_query, [e], e.workspace_id == ^workspace_id), else: base_query

    total = Repo.aggregate(base_query, :count)

    level_counts =
      Repo.all(
        base_query
        |> group_by([e], e.level)
        |> select([e], %{level: e.level, count: count(e.id)})
      )

    type_counts =
      Repo.all(
        base_query
        |> group_by([e], e.event_type)
        |> select([e], %{event_type: e.event_type, count: count(e.id)})
        |> order_by([e], desc: count(e.id))
        |> limit(10)
      )

    json(conn, %{
      stats: %{
        total: total,
        by_level: level_counts,
        top_event_types: type_counts
      }
    })
  end

  # --- Private helpers ---

  defp classify_signal(message) do
    mode = infer_mode(message)
    genre = infer_genre(message)
    type = infer_type(message)
    format = infer_format(message)
    structure = infer_structure(genre)

    %{
      mode: mode,
      genre: genre,
      type: type,
      format: format,
      structure: structure,
      noise_indicators: detect_noise(message),
      signal_strength: score_signal(message)
    }
  end

  defp infer_mode(message) do
    cond do
      message =~ ~r/```|def |defmodule |function |class |import / -> "Code"
      message =~ ~r/\|.*\||\[.*\].*:/ -> "Visual"
      true -> "Linguistic"
    end
  end

  defp infer_genre(message) do
    cond do
      message =~ ~r/\bfix\b|\bbug\b|\berror\b/i -> "BugReport"
      message =~ ~r/\bspec\b|\brequirement\b|\bmust\b|\bshall\b/i -> "Spec"
      message =~ ~r/\bdecision\b|\barchitecture\b|\badr\b/i -> "ADR"
      message =~ ~r/\bsummary\b|\bbrief\b|\bTL;?DR\b/i -> "Brief"
      message =~ ~r/\breport\b|\bmetrics\b|\bstatus\b/i -> "Report"
      message =~ ~r/\btask\b|\btodo\b|\baction\b/i -> "ActionItem"
      true -> "General"
    end
  end

  defp infer_type(message) do
    cond do
      message =~ ~r/^(do|run|create|update|delete|fix|build|deploy)\b/i -> "Direct"
      message =~ ~r/\bdecided\b|\bwill\b|\bcommitting\b/i -> "Commit"
      message =~ ~r/\bshould\b|\bconsider\b|\bpropose\b/i -> "Decide"
      message =~ ~r/\bFYI\b|\bnote\b|\baware\b/i -> "Inform"
      true -> "Inform"
    end
  end

  defp infer_format(message) do
    cond do
      message =~ ~r/^```/ -> "CodeBlock"
      message =~ ~r/^#+ / -> "Markdown"
      message =~ ~r/^\s*[-*]\s/ -> "BulletList"
      message =~ ~r/\|.*\|/ -> "Table"
      true -> "PlainText"
    end
  end

  defp infer_structure(genre) do
    case genre do
      "Spec" -> ["Overview", "Requirements", "Acceptance Criteria", "Out of Scope"]
      "BugReport" -> ["Summary", "Steps to Reproduce", "Expected", "Actual", "Fix"]
      "ADR" -> ["Context", "Decision", "Consequences", "Alternatives"]
      "Brief" -> ["Summary", "Key Points", "Action Items"]
      "Report" -> ["Summary", "Metrics", "Findings", "Next Steps"]
      "ActionItem" -> ["What", "Who", "By When", "Definition of Done"]
      _ -> ["Content"]
    end
  end

  defp detect_noise(message) do
    indicators = []
    indicators = if message =~ ~r/\bI think\b|\bmaybe\b|\bperhaps\b/i, do: ["hedging" | indicators], else: indicators
    indicators = if message =~ ~r/\bthat's a great\b|\bthank you for\b/i, do: ["filler" | indicators], else: indicators
    indicators = if String.length(message) > 2000, do: ["bandwidth_overload" | indicators], else: indicators
    indicators
  end

  defp score_signal(message) do
    word_count = message |> String.split() |> length()
    has_structure = message =~ ~r/^#|\n- |\n\*/m
    has_action = message =~ ~r/\b(do|create|fix|update|run|deploy|review)\b/i

    base = 5
    base = if word_count in 10..200, do: base + 2, else: base
    base = if has_structure, do: base + 2, else: base
    base = if has_action, do: base + 1, else: base
    min(base, 10)
  end

  defp level_to_signal_type("error"), do: "critical"
  defp level_to_signal_type("warn"), do: "warning"
  defp level_to_signal_type(_), do: "info"
end
