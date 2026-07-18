defmodule OptimalSystemAgent.Channels.HTTP.API.HooksRoutes do
  @moduledoc """
  Hook system introspection routes for the OSA HTTP API.

  Forwarded prefix: /hooks  (unrelated to /webhooks in CommandCenterRoutes).

  Effective routes:
    GET /  (forwarded as GET /) — registered hooks + per-event execution metrics

  Response shape:

      {
        "hooks": {
          "<event>": [ {"name": "security_check", "priority": 10}, ... ],
          ...
        },
        "metrics": {
          "<event>": {"calls": N, "total_us": N, "blocks": N, "avg_us": N},
          ...
        }
      }

  `list_hooks/0` already drops the handler function and opts, exposing only
  `name`/`priority`, so no PIDs or functions reach the JSON. Event keys are
  atoms internally and are stringified here so the TUI receives clean strings.
  On any failure the call is wrapped in try/rescue and returns empty maps —
  the endpoint never 500s the TUI.
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.Hooks.Dispatch

  plug(:match)
  plug(:dispatch)

  # ── GET / — registered hooks + metrics ──────────────────────────────

  get "/" do
    {hooks, metrics} =
      try do
        {stringify_event_keys(Dispatch.list_hooks()), stringify_event_keys(Dispatch.metrics())}
      rescue
        _ -> {%{}, %{}}
      catch
        :exit, _ -> {%{}, %{}}
      end

    json(conn, 200, %{hooks: hooks, metrics: metrics})
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Hooks endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Convert atom event keys to strings for clean JSON. Values from
  # list_hooks/0 (lists of %{name, priority}) and metrics/0 (numeric maps)
  # are already JSON-safe, so only the top-level keys need coercion.
  defp stringify_event_keys(map) when is_map(map) do
    Map.new(map, fn {event, value} -> {to_string(event), value} end)
  end

  defp stringify_event_keys(_), do: %{}
end