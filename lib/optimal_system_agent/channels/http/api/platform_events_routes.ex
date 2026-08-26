defmodule OptimalSystemAgent.Channels.HTTP.API.PlatformEventsRoutes do
  @moduledoc """
  Platform Events API routes.

  Forwarded prefix: /platform-events

  Routes:
    GET  /stream   → SSE stream (query params: os_id, type)
    GET  /history  → recent events (query params: limit, os_id, type)
    GET  /stats    → event statistics

  NOTE: Not yet wired — no `forward` in api.ex routes to this module.
  Scaffolded for future fleet/multi-OS event visibility.
  See Platform.EventBus moduledoc for activation steps.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Platform.EventBus

  plug(:match)
  plug(:dispatch)

  # -- GET /stream — SSE event stream ----------------------------------------

  get "/stream" do
    opts =
      []
      |> maybe_put(:os_id, conn.query_params["os_id"])
      |> maybe_put(:type, conn.query_params["type"])

    EventBus.stream(conn, opts)
  end

  # -- GET /history — recent events ------------------------------------------

  get "/history" do
    limit =
      case conn.query_params["limit"] do
        nil -> 500
        val -> min(String.to_integer(val), 500)
      end

    opts =
      [limit: limit]
      |> maybe_put(:os_id, conn.query_params["os_id"])
      |> maybe_put(:type, conn.query_params["type"])

    events = EventBus.history(opts)
    body = Jason.encode!(%{events: events, count: length(events)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # -- GET /stats — event statistics -----------------------------------------

  get "/stats" do
    body = Jason.encode!(EventBus.stats())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Platform events endpoint not found")
  end
end
