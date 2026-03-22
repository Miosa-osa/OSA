defmodule CanopyWeb.LogController do
  use CanopyWeb, :controller

  def stream(conn, params) do
    level = params["level"]
    source = params["source"]

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    Canopy.EventBus.subscribe(Canopy.EventBus.logs_topic())

    stream_loop(conn, level, source)
  end

  defp stream_loop(conn, level_filter, source_filter) do
    receive do
      %{event: event_type} = event ->
        if passes_filter?(event, level_filter, source_filter) do
          data = Jason.encode!(event)

          case Plug.Conn.chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
            {:ok, conn} -> stream_loop(conn, level_filter, source_filter)
            {:error, _} -> conn
          end
        else
          stream_loop(conn, level_filter, source_filter)
        end

      event ->
        if passes_filter?(event, level_filter, source_filter) do
          data = Jason.encode!(event)

          case Plug.Conn.chunk(conn, "data: #{data}\n\n") do
            {:ok, conn} -> stream_loop(conn, level_filter, source_filter)
            {:error, _} -> conn
          end
        else
          stream_loop(conn, level_filter, source_filter)
        end
    after
      30_000 ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, level_filter, source_filter)
          {:error, _} -> conn
        end
    end
  end

  defp passes_filter?(event, level_filter, source_filter) do
    level_ok =
      case level_filter do
        nil -> true
        lvl -> Map.get(event, :level) == lvl or Map.get(event, "level") == lvl
      end

    source_ok =
      case source_filter do
        nil -> true
        src -> Map.get(event, :source) == src or Map.get(event, "source") == src
      end

    level_ok and source_ok
  end
end
