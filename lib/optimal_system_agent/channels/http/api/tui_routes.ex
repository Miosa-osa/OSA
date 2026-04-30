defmodule OptimalSystemAgent.Channels.HTTP.API.TuiRoutes do
  @moduledoc """
  TUI-specific routes.

    GET  /tui/output  — SSE stream of agent output destined for the TUI
    POST /tui/input   — Receive text input from the TUI and dispatch to the agent loop

  The /stream/tui_output alias is handled directly in AgentRoutes so that it
  fits naturally into the /stream/* forwarding group. This module owns the
  /tui/* prefix forwarded from the parent API router.

  PubSub channel used: "osa:tui:output"

  Input body:
    { "input": "<message>", "session_id": "<optional>" }
  """
  use Plug.Router
  import Plug.Conn
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Agent.Loop

  plug(:match)
  plug(:dispatch)

  # ── GET /output — TUI SSE output stream ─────────────────────────────
  #
  # Streams agent output events on the shared "osa:tui:output" PubSub
  # topic. Any session writing to that topic will be forwarded here,
  # making the TUI a global observer rather than session-scoped.

  get "/output" do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:tui:output")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"channel\": \"tui_output\"}\n\n")

    Logger.debug("[TUI] SSE output stream opened by #{conn.assigns[:user_id]}")

    tui_sse_loop(conn)
  end

  # ── POST /input — accept input from the TUI ─────────────────────────
  #
  # Accepts JSON body: { "input": "...", "session_id": "..." }
  # Starts the agent loop for the session (creating one if absent) and
  # dispatches the message for processing. Events flow back over SSE.

  post "/input" do
    with %{"input" => input} when is_binary(input) and input != "" <- conn.body_params do
      user_id = conn.assigns[:user_id] || "anonymous"
      session_id = conn.body_params["session_id"] || generate_session_id()

      case Session.ensure_loop(session_id, user_id, :tui) do
        {:error, reason} ->
          Logger.warning("[TUI] Failed to ensure session loop: #{inspect(reason)}")

          json_error(
            conn,
            503,
            "session_unavailable",
            "Could not start session: #{inspect(reason)}"
          )

        _ ->
          opts = [channel: :tui]
          Task.start(fn -> Loop.process_message(session_id, input, opts) end)

          Logger.debug("[TUI] Input dispatched: session=#{session_id} user=#{user_id}")

          body = Jason.encode!(%{status: "processing", session_id: session_id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)
      end
    else
      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: input")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "TUI endpoint not found")
  end

  # ── SSE loop ─────────────────────────────────────────────────────────

  defp tui_sse_loop(conn) do
    receive do
      {:osa_event, event} ->
        event_type =
          case event do
            %{type: :system_event, event: sub} -> to_string(sub)
            %{type: t} -> to_string(t)
            _ -> "unknown"
          end

        case Jason.encode(event) do
          {:ok, data} ->
            Logger.debug("[TUI SSE] sending #{event_type}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                tui_sse_loop(conn)

              {:error, _} ->
                Logger.debug("[TUI] SSE client disconnected")
                conn
            end

          {:error, reason} ->
            Logger.warning("[TUI SSE] Failed to encode #{event_type}: #{inspect(reason)}")
            tui_sse_loop(conn)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> tui_sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end
end
