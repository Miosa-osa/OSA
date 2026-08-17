defmodule OptimalSystemAgent.Channels.HTTP.API.AgentRoutes do
  @moduledoc """
  Agent SSE stream routes.

    GET /tui_output   — SSE output stream for the TUI (alias for /tui/output)
    GET /:session_id  — SSE event stream for a session

  This module is forwarded to from the parent router at /stream, so routes
  are relative to that prefix.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  alias OptimalSystemAgent.Agent.ActiveSkills
  alias OptimalSystemAgent.Channels.HTTP.SessionAccess
  alias OptimalSystemAgent.Runtime.SessionManager
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET /tui_output — TUI SSE output stream (alias) ────────────────
  #
  # The Rust TUI connects to /api/v1/stream/tui_output. This named route
  # must appear before /:session_id so the router does not treat
  # "tui_output" as a session ID.

  get "/tui_output" do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:tui:output")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"channel\": \"tui_output\"}\n\n")

    Logger.debug("[TUI] /stream/tui_output opened by #{conn.assigns[:user_id]}")

    sse_loop(conn, "tui_output")
  end

  # ── GET /:session_id ───────────────────────────────────────────────

  get "/:session_id" do
    session_id = conn.params["session_id"]
    user_id = conn.assigns[:user_id]

    case SessionAccess.authorize(session_id, user_id) do
      :ok ->
        # Opening the session's event stream is how a client ANNOUNCES a session
        # id it holds. The TUI mints its own id locally at startup
        # (`generate_session_id/0`) and the backend otherwise learns of it only
        # when the first message arrives — so between launch and first turn the
        # id is indistinguishable from garbage, and anything that gates on
        # `session_exists?/1` (e.g. POST /sessions/:id/provider) 404s a session
        # the user is legitimately sitting in. Tracking on subscribe records the
        # id without starting a Loop, which is exactly the "created or tracked by
        # a runtime channel" case `tracked_session?/1` exists for.
        SessionManager.track_session(session_id, %{
          user_id: user_id || "anonymous",
          channel: :sse
        })

        Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        {:ok, conn} =
          chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

        replay_active_skills(session_id)

        sse_loop(conn, session_id)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Session not found")
    end
  end

  defp replay_active_skills(session_id) do
    Enum.each(ActiveSkills.list(session_id), fn skill ->
      send(self(), {:osa_event, %{type: :skill_selected, skill: skill}})
    end)
  end

  match _ do
    json_error(conn, 404, "not_found", "Agent endpoint not found")
  end

  # ── SSE Loop ────────────────────────────────────────────────────────

  defp sse_loop(conn, session_id) do
    receive do
      {:osa_event, event} ->
        # system_event wraps sub-events (streaming_token, thinking_delta, etc.)
        # — unwrap so the SSE event type matches what the TUI parser expects.
        event_type =
          case event do
            %{type: :system_event, event: sub} -> to_string(sub)
            %{type: t} -> to_string(t)
            _ -> "unknown"
          end

        case Jason.encode(event) do
          {:ok, data} ->
            Logger.debug("[SSE] sending #{event_type} to #{session_id}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                sse_loop(conn, session_id)

              {:error, _reason} ->
                Logger.debug("SSE client disconnected for session #{session_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] Failed to encode #{event_type} event: #{inspect(reason)}")
            sse_loop(conn, session_id)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end
end
