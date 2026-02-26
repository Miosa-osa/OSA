defmodule OptimalSystemAgent.Channels.HTTP.API do
  @moduledoc """
  Authenticated API routes — all endpoints under /api/v1.

  Every route goes through JWT verification first. In dev mode (require_auth: false),
  unauthenticated requests are allowed with an "anonymous" user_id.
  """
  use Plug.Router
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Skills.Registry, as: Skills
  alias OptimalSystemAgent.Machines
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @known_channels %{
    "cli" => :cli,
    "http" => :http,
    "telegram" => :telegram,
    "discord" => :discord,
    "slack" => :slack,
    "whatsapp" => :whatsapp,
    "webhook" => :webhook,
    "filesystem" => :filesystem
  }

  plug :authenticate
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  # ── POST /orchestrate ───────────────────────────────────────────────

  post "/orchestrate" do
    with %{"input" => input} <- conn.body_params do
      user_id = conn.body_params["user_id"] || conn.assigns[:user_id]
      session_id = conn.body_params["session_id"] || generate_session_id()
      workspace_id = conn.body_params["workspace_id"]

      start_time = System.monotonic_time(:millisecond)

      # Ensure an agent loop exists for this session
      ensure_loop(session_id, user_id, workspace_id)

      # Process through the agent loop (same pipeline as CLI)
      case Loop.process_message(session_id, input) do
        {:ok, response} ->
          execution_ms = System.monotonic_time(:millisecond) - start_time
          signal = Classifier.classify(input, :http)

          body = Jason.encode!(%{
            session_id: session_id,
            output: response,
            signal: signal_to_map(signal),
            skills_used: [],
            iteration_count: 0,
            execution_ms: execution_ms,
            metadata: %{}
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:filtered, signal} ->
          body = Jason.encode!(%{
            error: "signal_filtered",
            code: "SIGNAL_BELOW_THRESHOLD",
            details: "Signal weight #{signal.weight} below threshold",
            signal: signal_to_map(signal)
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(422, body)

        {:error, reason} ->
          json_error(conn, 500, "agent_error", to_string(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: input")
    end
  end

  # ── GET /stream/:session_id ─────────────────────────────────────────

  get "/stream/:session_id" do
    session_id = conn.params["session_id"]
    user_id = conn.assigns[:user_id]

    # Validate session ownership before allowing SSE subscription
    case validate_session_owner(session_id, user_id) do
      :ok ->
        # Subscribe to this session's PubSub events
        Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        # Send initial connection event
        {:ok, conn} = chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

        # Enter SSE loop — blocks until client disconnects
        sse_loop(conn, session_id)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Session not found")
    end
  end

  # ── POST /classify ──────────────────────────────────────────────────

  post "/classify" do
    with %{"message" => message} <- conn.body_params do
      channel = parse_channel(conn.body_params["channel"])
      signal = Classifier.classify(message, channel)

      body = Jason.encode!(%{signal: signal_to_map(signal)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: message")
    end
  end

  # ── GET /skills ─────────────────────────────────────────────────────

  get "/skills" do
    tools = Skills.list_tools()

    body = Jason.encode!(%{
      skills: tools,
      count: length(tools)
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /skills/:name/execute ──────────────────────────────────────

  post "/skills/:name/execute" do
    skill_name = conn.params["name"]
    arguments = conn.body_params["arguments"] || %{}

    case Skills.execute(skill_name, arguments) do
      {:ok, result} ->
        body = Jason.encode!(%{
          skill: skill_name,
          status: "completed",
          result: result
        })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 422, "skill_error", to_string(reason))
    end
  end

  # ── POST /memory ────────────────────────────────────────────────────

  post "/memory" do
    with %{"content" => content} <- conn.body_params do
      category = conn.body_params["category"] || "general"
      Memory.remember(content, category)

      body = Jason.encode!(%{status: "saved", category: category})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: content")
    end
  end

  # ── GET /memory/recall ──────────────────────────────────────────────

  get "/memory/recall" do
    content = Memory.recall()

    body = Jason.encode!(%{content: content})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /machines ───────────────────────────────────────────────────

  get "/machines" do
    active = Machines.active()

    body = Jason.encode!(%{
      machines: active,
      count: length(active)
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /webhooks/:trigger_id ───────────────────────────────────────
  #
  # Inbound webhook receiver. Accepts any JSON payload and forwards it to
  # the Scheduler as a named trigger event. The Scheduler matches the
  # trigger_id against enabled triggers in TRIGGERS.json and fires the
  # corresponding action (agent task or shell command).
  #
  # Example:
  #   curl -X POST http://localhost:8089/api/v1/webhooks/new-lead \
  #        -H 'Content-Type: application/json' \
  #        -d '{"company": "Acme", "email": "ceo@acme.com"}'

  post "/webhooks/:trigger_id" do
    trigger_id = conn.params["trigger_id"]
    payload = conn.body_params || %{}

    Logger.info("Webhook received for trigger '#{trigger_id}'")

    Scheduler.fire_trigger(trigger_id, payload)

    body = Jason.encode!(%{
      status: "accepted",
      trigger_id: trigger_id,
      message: "Trigger queued for execution"
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  # ── GET /scheduler/jobs ──────────────────────────────────────────────
  #
  # List all cron jobs from CRONS.json with their current state
  # (failure_count, circuit_open).

  get "/scheduler/jobs" do
    jobs = Scheduler.list_jobs()

    body = Jason.encode!(%{
      jobs: jobs,
      count: length(jobs)
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /scheduler/reload ───────────────────────────────────────────
  #
  # Reload CRONS.json and TRIGGERS.json without restarting the scheduler.

  post "/scheduler/reload" do
    Scheduler.reload_crons()

    body = Jason.encode!(%{status: "reloading", message: "Scheduler reload queued"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  # ── Catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end

  # ── JWT Authentication Plug ─────────────────────────────────────────

  defp authenticate(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Auth.verify_token(token) do
          {:ok, claims} ->
            conn
            |> assign(:user_id, claims["user_id"])
            |> assign(:workspace_id, claims["workspace_id"])
            |> assign(:claims, claims)

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "INVALID_TOKEN"}))
            |> halt()
        end

      _ ->
        if Application.get_env(:optimal_system_agent, :require_auth, false) do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "MISSING_TOKEN"}))
          |> halt()
        else
          Logger.debug("HTTP request without auth — dev mode, allowing")
          conn
          |> assign(:user_id, "anonymous")
          |> assign(:workspace_id, nil)
          |> assign(:claims, %{})
        end
    end
  end

  # ── Session Ownership Validation ────────────────────────────────────

  defp validate_session_owner(session_id, _user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] when is_pid(pid) ->
        # TODO: Add Loop.get_owner(session_id) for strict per-user ownership validation
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  # ── SSE Loop ────────────────────────────────────────────────────────

  defp sse_loop(conn, session_id) do
    receive do
      {:osa_event, event} ->
        event_type = Map.get(event, :type, "unknown") |> to_string()
        data = Jason.encode!(event)

        case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
          {:ok, conn} ->
            sse_loop(conn, session_id)

          {:error, _reason} ->
            Logger.debug("SSE client disconnected for session #{session_id}")
            conn
        end

    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp ensure_loop(session_id, user_id, _workspace_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        {:ok, _pid} =
          DynamicSupervisor.start_child(
            OptimalSystemAgent.Channels.Supervisor,
            {Loop, session_id: session_id, user_id: user_id, channel: :http}
          )

        :ok
    end
  end

  defp signal_to_map(%Classifier{} = signal) do
    %{
      mode: signal.mode,
      genre: signal.genre,
      type: signal.type,
      format: signal.format,
      weight: signal.weight,
      channel: signal.channel,
      timestamp: signal.timestamp |> DateTime.to_iso8601()
    }
  end

  defp parse_channel(nil), do: :http
  defp parse_channel(name) when is_binary(name) do
    Map.get(@known_channels, String.downcase(name), :http)
  end

  defp generate_session_id do
    "http_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp json_error(conn, status, error, details) do
    body = Jason.encode!(%{error: error, details: details})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
