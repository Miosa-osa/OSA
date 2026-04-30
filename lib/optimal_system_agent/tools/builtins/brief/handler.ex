defmodule OptimalSystemAgent.Tools.Builtins.Brief.Handler do
  @moduledoc """
  Validation, permission, and execution for `brief`.

  Aggregates recent memory entries by time window (and optional topic
  filter) then assembles a one-paragraph summary. The Memory.Store recall
  path is shared with `memory_recall` — same keyword index, same scoring.
  """

  alias OptimalSystemAgent.Tools.Builtins.Brief.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input) do
    window = Map.get(input, "window_hours", Constants.default_window_hours())
    topic = Map.get(input, "topic")

    cond do
      not is_integer(window) or window not in Constants.valid_windows() ->
        {:error, "window_hours must be one of: #{Enum.join(Constants.valid_windows(), ", ")}",
         -32_602}

      topic != nil and not is_binary(topic) ->
        {:error, "topic must be a string", -32_602}

      topic != nil and String.trim(topic) == "" ->
        {:error, "topic must not be blank", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(_, _ctx),
    do: {:error, "Input must be a map", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(input, _ctx) do
    window_hours = Map.get(input, "window_hours", Constants.default_window_hours())
    topic = Map.get(input, "topic")

    query = build_query(topic)
    cutoff_dt = DateTime.add(DateTime.utc_now(), -window_hours * 3600, :second)

    entries = recall_entries(query, window_hours)

    recent =
      entries
      |> Enum.filter(fn e ->
        case Map.get(e, :inserted_at) do
          nil -> true
          dt -> DateTime.compare(dt, cutoff_dt) == :gt
        end
      end)
      |> Enum.take(Constants.max_recent_entries())

    brief = format_brief(recent, window_hours, topic)
    {:ok, brief}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp build_query(nil), do: "recent activity task tool"
  defp build_query(topic), do: topic

  defp recall_entries(query, window_hours) do
    if function_exported?(OptimalSystemAgent.Memory.Store, :handle_call, 3) do
      case GenServer.call(
             OptimalSystemAgent.Memory.Store,
             {:recall, query, [limit: Constants.max_recent_entries()]},
             5_000
           ) do
        {:ok, entries} -> entries
        _ -> []
      end
    else
      fallback_entries(window_hours)
    end
  rescue
    _ -> []
  end

  defp fallback_entries(_window_hours), do: []

  defp format_brief([], window_hours, topic) do
    # {topic}"", else: ""
    scope = if topic, do: " matching "
    "No activity recorded#{scope} in the last #{window_hours}h."
  end

  defp format_brief(entries, window_hours, topic) do
    scope = if topic, do: " (filtered: #{topic})", else: ""
    count = length(entries)

    summary_lines =
      entries
      |> Enum.map(fn e ->
        content = Map.get(e, :content, Map.get(e, "content", ""))
        category = Map.get(e, :category, Map.get(e, "category", "note"))
        ts = format_ts(Map.get(e, :inserted_at))
        "[#{category}#{ts}] #{truncate(content, 120)}"
      end)
      |> Enum.join("; ")

    header = "Last #{window_hours}h summary#{scope} — #{count} event(s): "

    (header <> summary_lines)
    |> String.slice(0, Constants.max_brief_chars())
  end

  defp format_ts(nil), do: ""

  defp format_ts(%DateTime{} = dt) do
    " @#{Calendar.strftime(dt, "%H:%M")}"
  end

  defp format_ts(_), do: ""

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
  end

  defp truncate(other, _), do: inspect(other)
end
