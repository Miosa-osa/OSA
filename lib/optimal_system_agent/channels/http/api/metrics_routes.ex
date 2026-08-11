defmodule OptimalSystemAgent.Channels.HTTP.API.MetricsRoutes do
  @moduledoc """
  Telemetry metrics introspection routes for the OSA HTTP API.

  Forwarded prefix: /metrics

  Effective routes:
    GET /  (forwarded as GET /api/v1/metrics)
      Computed telemetry summary sourced from
      `OptimalSystemAgent.Telemetry.Metrics.get_summary/0`: per-tool and
      per-provider latency (count / avg / p99), session activity, the
      noise-filter pass rate, and the signal-weight histogram. A small set
      of pre-aggregated headline `cards` is derived here so the TUI can
      render at-a-glance metric cards without re-summing maps.

  All atom keys (bucket labels) are stringified so the TUI receives clean
  JSON. On any failure the call is wrapped in try/rescue and returns a
  zeroed-but-well-formed payload — the endpoint never 500s the TUI.

  Response shape:

      {
        "cards": [
          {"key": "turns", "label": "Turns", "value": 42, "note": "this session", "tone": "neutral"},
          ...
        ],
        "tools": [
          {"name": "read_file", "count": 12, "avg_ms": 3.5, "min_ms": 1, "max_ms": 40, "p99_ms": 38}
        ],
        "providers": [
          {"name": "zhipu", "count": 30, "avg_ms": 812.0, "p99_ms": 1900}
        ],
        "signal_weights": [ {"bucket": "0.0-0.2", "count": 3}, ... ],
        "noise_filter_rate": 12.5,
        "session": {"total_turns": 42, "messages_today": 7, "active_sessions": 2}
      }
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Telemetry.Metrics

  plug(:match)
  plug(:dispatch)

  # ── GET / — computed telemetry summary ──────────────────────────────

  get "/" do
    payload =
      try do
        build_payload(Metrics.get_summary())
      rescue
        _ -> empty_payload()
      catch
        :exit, _ -> empty_payload()
      end

    json(conn, 200, payload)
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Metrics endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp build_payload(summary) when is_map(summary) do
    tools = serialize_tools(Map.get(summary, :tool_executions, %{}))
    providers = serialize_providers(Map.get(summary, :provider_latency, %{}))
    session = serialize_session(Map.get(summary, :session_stats, %{}))
    filter_rate = to_float(Map.get(summary, :noise_filter_rate, 0.0))

    %{
      cards: build_cards(tools, providers, session, filter_rate),
      tools: tools,
      providers: providers,
      signal_weights: serialize_buckets(Map.get(summary, :signal_weight_distribution, %{})),
      noise_filter_rate: filter_rate,
      session: session
    }
  end

  defp build_payload(_), do: empty_payload()

  # Headline cards, pre-aggregated so the TUI just renders them.
  defp build_cards(tools, providers, session, filter_rate) do
    tool_calls = Enum.reduce(tools, 0, fn t, acc -> acc + t.count end)
    provider_calls = Enum.reduce(providers, 0, fn p, acc -> acc + p.count end)

    [
      %{
        key: "turns",
        label: "Turns",
        value: session.total_turns,
        note: "this session",
        tone: "neutral"
      },
      %{
        key: "messages",
        label: "Messages",
        value: session.messages_today,
        note: "today",
        tone: "neutral"
      },
      %{
        key: "tool_calls",
        label: "Tool Calls",
        value: tool_calls,
        note: "#{length(tools)} tools",
        tone: "good"
      },
      %{
        key: "provider_calls",
        label: "LLM Calls",
        value: provider_calls,
        note: "#{length(providers)} providers",
        tone: "good"
      },
      %{
        key: "filter_rate",
        label: "Noise Filter",
        value: round(filter_rate),
        note: "% filtered",
        tone: filter_tone(filter_rate)
      },
      %{
        key: "sessions",
        label: "Sessions",
        value: session.active_sessions,
        note: "active",
        tone: "neutral"
      }
    ]
  end

  defp filter_tone(rate) when rate >= 50.0, do: "warn"
  defp filter_tone(_), do: "neutral"

  defp serialize_tools(map) when is_map(map) do
    map
    |> Enum.map(fn {name, e} ->
      %{
        name: to_string(name),
        count: to_int(Map.get(e, :count, 0)),
        avg_ms: to_float(Map.get(e, :avg_ms, 0.0)),
        min_ms: to_int(Map.get(e, :min_ms, 0)),
        max_ms: to_int(Map.get(e, :max_ms, 0)),
        p99_ms: to_int(Map.get(e, :p99_ms, 0))
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp serialize_tools(_), do: []

  defp serialize_providers(map) when is_map(map) do
    map
    |> Enum.map(fn {name, e} ->
      %{
        name: to_string(name),
        count: to_int(Map.get(e, :count, 0)),
        avg_ms: to_float(Map.get(e, :avg_ms, 0.0)),
        p99_ms: to_int(Map.get(e, :p99_ms, 0))
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp serialize_providers(_), do: []

  defp serialize_session(stats) when is_map(stats) do
    turns_by = Map.get(stats, :turns_by_session, %{})
    active = if is_map(turns_by), do: map_size(turns_by), else: 0

    %{
      total_turns: to_int(Map.get(stats, :total_turns, 0)),
      messages_today: to_int(Map.get(stats, :messages_today, 0)),
      active_sessions: active
    }
  end

  defp serialize_session(_), do: %{total_turns: 0, messages_today: 0, active_sessions: 0}

  defp serialize_buckets(map) when is_map(map) do
    map
    |> Enum.map(fn {bucket, count} -> {to_string(bucket), to_int(count)} end)
    |> Enum.sort_by(fn {bucket, _} -> bucket end)
    |> Enum.map(fn {bucket, count} -> %{bucket: bucket, count: count} end)
  end

  defp serialize_buckets(_), do: []

  defp empty_payload do
    session = %{total_turns: 0, messages_today: 0, active_sessions: 0}

    %{
      cards: build_cards([], [], session, 0.0),
      tools: [],
      providers: [],
      signal_weights: [],
      noise_filter_rate: 0.0,
      session: session
    }
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: round(n)
  defp to_int(_), do: 0

  defp to_float(n) when is_float(n), do: Float.round(n, 2)
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: 0.0
end
