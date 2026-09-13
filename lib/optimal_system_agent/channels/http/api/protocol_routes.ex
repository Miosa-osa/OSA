defmodule OptimalSystemAgent.Channels.HTTP.API.ProtocolRoutes do
  @moduledoc """
  Protocol and event bus routes forwarded from multiple prefixes.

  Forwarded prefixes → effective routes:
    /events → POST /, GET /stream
    /oscp   → POST /
    /tasks  → GET /history

  Effective endpoints:
    POST /events
    GET  /events/stream
    POST /oscp
    GET  /tasks/history
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias MiosaSignal.CloudEvent
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Tasks

  plug(:match)
  plug(:dispatch)

  # ── POST / ────────────────────────────────────────────────────────
  # Handles POST /events and POST /oscp after prefix strip.
  # Disambiguate by script_name.

  post "/" do
    case List.last(conn.script_name) do
      "oscp" -> handle_oscp(conn)
      _ -> handle_publish_event(conn)
    end
  end

  # ── GET /stream — events SSE ──────────────────────────────────────

  get "/stream" do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:events:firehose")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: connected\ndata: {}\n\n")
    cloud_events_sse_loop(conn)
  end

  # ── GET /history — task history ───────────────────────────────────

  get "/history" do
    opts =
      []
      |> maybe_put(:agent_id, conn.params["agent_id"])
      |> maybe_put(:status, parse_task_status(conn.params["status"]))
      |> maybe_put(:limit, parse_int(conn.params["limit"]))

    tasks = Tasks.list_history(opts)

    body = Jason.encode!(%{tasks: tasks, count: length(tasks)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Protocol endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

  defp handle_publish_event(conn) do
    case CloudEvent.decode(Jason.encode!(conn.body_params)) do
      {:ok, event} ->
        bus_event = CloudEvent.to_bus_event(event)
        Bus.emit(:system_event, bus_event)

        body = Jason.encode!(%{status: "accepted", event_id: event.id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, body)

      {:error, reason} ->
        json_error(conn, 400, "invalid_cloud_event", to_string(reason))
    end
  end

  defp handle_oscp(conn) do
    json_body = Jason.encode!(conn.body_params)

    case CloudEvent.decode(json_body) do
      {:ok, event} ->
        route_oscp_event(event)

        body = Jason.encode!(%{status: "accepted", event_id: event.id, type: event.type})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, body)

      {:error, reason} ->
        json_error(conn, 400, "invalid_oscp_event", to_string(reason))
    end
  end

  # ── CloudEvents SSE Loop ────────────────────────────────────────────

  defp cloud_events_sse_loop(conn) do
    receive do
      {:osa_event, event} ->
        cloud_event = CloudEvent.from_bus_event(event)

        case CloudEvent.encode(cloud_event) do
          {:ok, json} ->
            case chunk(conn, "event: #{cloud_event.type}\ndata: #{json}\n\n") do
              {:ok, conn} -> cloud_events_sse_loop(conn)
              {:error, _} -> conn
            end

          _ ->
            cloud_events_sse_loop(conn)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> cloud_events_sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  # ── OSCP Event Routing ──────────────────────────────────────────────

  defp route_oscp_event(%CloudEvent{type: "oscp.heartbeat"}) do
    # Fleet.Registry backend not present in this build; heartbeat is dropped.
    {:error, "Fleet.Registry backend not present in this build"}
  end

  defp route_oscp_event(%CloudEvent{type: "oscp.instruction"} = event) do
    task_id = event.data["task_id"] || event.data[:task_id]
    agent_id = event.data["agent_id"] || event.data[:agent_id]
    payload = event.data["payload"] || event.data[:payload] || %{}

    if task_id && agent_id do
      Tasks.enqueue(task_id, agent_id, payload)
    else
      Logger.warning("[API] OSCP instruction missing task_id or agent_id")
    end
  end

  defp route_oscp_event(%CloudEvent{type: "oscp.result"} = event) do
    task_id = event.data["task_id"] || event.data[:task_id]
    status = event.data["status"] || event.data[:status]

    cond do
      is_nil(task_id) ->
        Logger.warning("[API] OSCP result missing task_id")

      status in ["failed", :failed] ->
        error = event.data["error"] || event.data[:error] || "unknown error"
        Tasks.fail_queued(task_id, error)

      true ->
        output = event.data["output"] || event.data[:output] || %{}
        Tasks.complete_queued(task_id, output)
    end
  end

  defp route_oscp_event(%CloudEvent{type: "oscp.signal"} = event) do
    Bus.emit(:system_event, CloudEvent.to_bus_event(event))
  end

  defp route_oscp_event(%CloudEvent{} = event) do
    Logger.warning("[API] Unknown OSCP type: #{event.type}")
  end
end
