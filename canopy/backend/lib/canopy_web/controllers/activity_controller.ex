defmodule CanopyWeb.ActivityController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.ActivityEvent
  import Ecto.Query

  def index(conn, params) do
    workspace_id = params["workspace_id"]
    agent_id = params["agent_id"]
    event_type = params["event_type"]
    level = params["level"]
    limit = min(String.to_integer(params["limit"] || "50"), 200)
    offset = String.to_integer(params["offset"] || "0")

    query =
      from e in ActivityEvent,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        offset: ^offset

    query = if workspace_id, do: where(query, [e], e.workspace_id == ^workspace_id), else: query
    query = if agent_id, do: where(query, [e], e.agent_id == ^agent_id), else: query
    query = if event_type, do: where(query, [e], e.event_type == ^event_type), else: query
    query = if level, do: where(query, [e], e.level == ^level), else: query

    events = Repo.all(query)
    total = Repo.aggregate(ActivityEvent, :count)

    json(conn, %{events: Enum.map(events, &serialize/1), total: total})
  end

  def stream(conn, _params) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    Canopy.EventBus.subscribe(Canopy.EventBus.activity_topic())

    stream_loop(conn)
  end

  defp stream_loop(conn) do
    receive do
      %{event: event_type} = event ->
        data = Jason.encode!(event)

        case Plug.Conn.chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end

      event ->
        data = Jason.encode!(event)

        case Plug.Conn.chunk(conn, "data: #{data}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    after
      30_000 ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp serialize(%ActivityEvent{} = e) do
    %{
      id: e.id,
      event_type: e.event_type,
      message: e.message,
      metadata: e.metadata,
      level: e.level,
      workspace_id: e.workspace_id,
      agent_id: e.agent_id,
      inserted_at: e.inserted_at
    }
  end
end
