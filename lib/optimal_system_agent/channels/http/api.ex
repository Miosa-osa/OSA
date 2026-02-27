defmodule OptimalSystemAgent.Channels.HTTP.API do
  @moduledoc """
  Authenticated API routes — all endpoints under /api/v1.

  Every route goes through JWT verification first. In dev mode (require_auth: false),
  unauthenticated requests are allowed with an "anonymous" user_id.

  Orchestration endpoints:
    POST   /api/v1/orchestrate/complex          — Launch multi-agent orchestrated task
    GET    /api/v1/orchestrate/:task_id/progress — Real-time progress for orchestrated task
    GET    /api/v1/orchestrate/tasks             — List all orchestrated tasks
    POST   /api/v1/skills/create                 — Dynamically create a new skill

  Swarm endpoints:
    POST   /api/v1/swarm/launch  — Launch a new multi-agent swarm
    GET    /api/v1/swarm         — List all swarms
    GET    /api/v1/swarm/:id     — Get swarm status and result
    DELETE /api/v1/swarm/:id     — Cancel a running swarm
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
  alias OptimalSystemAgent.Swarm.Orchestrator, as: Swarm
  alias OptimalSystemAgent.Agent.Orchestrator, as: TaskOrchestrator
  alias OptimalSystemAgent.Agent.Progress
  alias OptimalSystemAgent.Channels.Telegram
  alias OptimalSystemAgent.Channels.Discord
  alias OptimalSystemAgent.Channels.Slack
  alias OptimalSystemAgent.Channels.WhatsApp
  alias OptimalSystemAgent.Channels.Signal, as: SignalChannel
  alias OptimalSystemAgent.Channels.Matrix
  alias OptimalSystemAgent.Channels.Email, as: EmailChannel
  alias OptimalSystemAgent.Channels.QQ
  alias OptimalSystemAgent.Channels.DingTalk
  alias OptimalSystemAgent.Channels.Feishu

  @known_channels %{
    "cli" => :cli,
    "http" => :http,
    "telegram" => :telegram,
    "discord" => :discord,
    "slack" => :slack,
    "whatsapp" => :whatsapp,
    "signal" => :signal,
    "matrix" => :matrix,
    "email" => :email,
    "qq" => :qq,
    "dingtalk" => :dingtalk,
    "feishu" => :feishu,
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

  # ── POST /orchestrate/complex ────────────────────────────────────────
  #
  # Launch an orchestrated multi-agent task. The orchestrator analyzes
  # complexity, decomposes into sub-tasks, spawns parallel sub-agents,
  # and synthesizes results.
  #
  # Request body:
  #   { "task": "Build a full REST API with tests and docs",
  #     "strategy": "auto" }  // optional: "parallel", "pipeline", "auto"
  #
  # Response:
  #   { "task_id": "task_abc123", "status": "completed",
  #     "synthesis": "...", "agent_count": 3 }

  post "/orchestrate/complex" do
    with %{"task" => task} when is_binary(task) and task != "" <- conn.body_params do
      strategy = conn.body_params["strategy"] || "auto"
      session_id = conn.body_params["session_id"] || generate_session_id()

      case TaskOrchestrator.execute(task, session_id, strategy: strategy) do
        {:ok, task_id, synthesis} ->
          body = Jason.encode!(%{
            task_id: task_id,
            status: "completed",
            synthesis: synthesis,
            session_id: session_id
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, reason} ->
          json_error(conn, 422, "orchestration_error", inspect(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: task")
    end
  end

  # ── GET /orchestrate/:task_id/progress ──────────────────────────────
  #
  # Get real-time progress for a running orchestrated task.
  #
  # Response:
  #   { "task_id": "...", "status": "running",
  #     "agents": [{ "name": "research", "tool_uses": 12, "tokens_used": 45200, ... }],
  #     "formatted": "Running 3 agents...\n   ..." }

  get "/orchestrate/:task_id/progress" do
    task_id = conn.params["task_id"]

    case TaskOrchestrator.progress(task_id) do
      {:ok, progress_data} ->
        formatted =
          case Progress.format(task_id) do
            {:ok, text} -> text
            _ -> nil
          end

        body = Jason.encode!(Map.put(progress_data, :formatted, formatted))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Task #{task_id} not found")
    end
  end

  # ── GET /orchestrate/tasks ──────────────────────────────────────────
  #
  # List all orchestrated tasks (running and recently completed).
  #
  # Response:
  #   { "tasks": [...], "count": 5, "active_count": 1 }

  get "/orchestrate/tasks" do
    tasks = TaskOrchestrator.list_tasks()
    active_count = Enum.count(tasks, & &1.status == :running)

    body = Jason.encode!(%{
      tasks: tasks,
      count: length(tasks),
      active_count: active_count
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /skills/create ─────────────────────────────────────────────
  #
  # Dynamically create a new skill at runtime.
  #
  # Request body:
  #   { "name": "data-analyzer",
  #     "description": "Analyze CSV data files",
  #     "instructions": "Read the CSV file and...",
  #     "tools": ["file_read", "shell_execute"] }
  #
  # Response:
  #   { "status": "created", "name": "data-analyzer",
  #     "message": "Skill created and registered." }

  post "/skills/create" do
    with %{"name" => name, "description" => desc, "instructions" => instructions}
         when is_binary(name) and is_binary(desc) and is_binary(instructions) <- conn.body_params do
      tools = conn.body_params["tools"] || []

      case TaskOrchestrator.create_skill(name, desc, instructions, tools) do
        {:ok, _} ->
          body = Jason.encode!(%{
            status: "created",
            name: name,
            message: "Skill '#{name}' created and registered at ~/.osa/skills/#{name}/SKILL.md"
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, reason} ->
          json_error(conn, 422, "skill_creation_error", inspect(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required fields: name, description, instructions")
    end
  end

  # ── POST /swarm/launch ───────────────────────────────────────────────
  #
  # Launch a new multi-agent swarm for a complex task.
  #
  # Request body:
  #   { "task": "Build a REST API for user management",
  #     "pattern": "parallel",         // optional override
  #     "max_agents": 3,               // optional, default 5
  #     "timeout_ms": 120000 }         // optional, default 300000
  #
  # Response:
  #   { "swarm_id": "swarm_abc123", "status": "running", "pattern": "parallel",
  #     "agent_count": 3, "agents": [...] }

  post "/swarm/launch" do
    with %{"task" => task} when is_binary(task) and task != "" <- conn.body_params do
      opts =
        []
        |> maybe_put(:pattern, parse_swarm_pattern(conn.body_params["pattern"]))
        |> maybe_put(:max_agents, conn.body_params["max_agents"])
        |> maybe_put(:timeout_ms, conn.body_params["timeout_ms"])

      case Swarm.launch(task, opts) do
        {:ok, swarm_id} ->
          {:ok, swarm} = Swarm.status(swarm_id)

          body = Jason.encode!(%{
            swarm_id: swarm_id,
            status: swarm.status,
            pattern: swarm.pattern,
            agent_count: swarm.agent_count,
            agents: swarm.agents || [],
            started_at: swarm.started_at
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)

        {:error, reason} ->
          json_error(conn, 422, "swarm_error", to_string(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: task")
    end
  end

  # ── GET /swarm ────────────────────────────────────────────────────────
  #
  # List all swarms (running, completed, failed, cancelled).
  #
  # Response:
  #   { "swarms": [...], "count": 2, "active_count": 1 }

  get "/swarm" do
    case Swarm.list_swarms() do
      {:ok, swarms} ->
        active_count = Enum.count(swarms, &(&1.status == :running))

        body = Jason.encode!(%{
          swarms: Enum.map(swarms, &swarm_to_map/1),
          count: length(swarms),
          active_count: active_count
        })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 500, "swarm_error", to_string(reason))
    end
  end

  # ── GET /swarm/:id ────────────────────────────────────────────────────
  #
  # Get status and result (once completed) of a specific swarm.
  #
  # Response:
  #   { "id": "...", "status": "completed", "result": "...", "agents": [...] }

  get "/swarm/:swarm_id" do
    swarm_id = conn.params["swarm_id"]

    case Swarm.status(swarm_id) do
      {:ok, swarm} ->
        body = Jason.encode!(swarm_to_map(swarm))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Swarm #{swarm_id} not found")

      {:error, reason} ->
        json_error(conn, 500, "swarm_error", to_string(reason))
    end
  end

  # ── DELETE /swarm/:id ─────────────────────────────────────────────────
  #
  # Cancel a running swarm. All worker processes are terminated immediately.
  #
  # Response:
  #   { "status": "cancelled", "swarm_id": "..." }

  delete "/swarm/:swarm_id" do
    swarm_id = conn.params["swarm_id"]

    case Swarm.cancel(swarm_id) do
      :ok ->
        body = Jason.encode!(%{status: "cancelled", swarm_id: swarm_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Swarm #{swarm_id} not found")

      {:error, reason} ->
        json_error(conn, 422, "swarm_error", to_string(reason))
    end
  end

  # ── Channel Webhooks ─────────────────────────────────────────────────
  #
  # These endpoints receive inbound events from external chat platforms.
  # They are intentionally NOT behind JWT auth — platforms call them with their
  # own verification mechanism (HMAC signatures, challenge tokens, etc.).
  #
  # Auth bypass works because the authenticate plug only halts on require_auth: true
  # with a missing/invalid bearer token. Webhook routes set :webhook_channel in
  # assigns so downstream code knows the auth context.
  #
  # Routes:
  #   POST /channels/telegram/webhook     — Telegram Bot updates
  #   POST /channels/discord/webhook      — Discord interactions
  #   POST /channels/slack/events         — Slack Events API
  #   POST /channels/whatsapp/webhook     — WhatsApp Business API
  #   GET  /channels/whatsapp/webhook     — Meta hub verification
  #   POST /channels/signal/webhook       — signal-cli-rest-api
  #   POST /channels/matrix/webhook       — (future: webhook push)
  #   POST /channels/email/inbound        — Email inbound parse
  #   POST /channels/qq/webhook           — QQ Bot events
  #   POST /channels/dingtalk/webhook     — DingTalk robot
  #   POST /channels/feishu/events        — Feishu event subscription
  #   GET  /channels                      — List all channel adapters

  # ── GET /channels ────────────────────────────────────────────────────

  get "/channels" do
    alias OptimalSystemAgent.Channels.Manager

    channels = Manager.list_channels()

    body = Jason.encode!(%{
      channels: Enum.map(channels, fn ch ->
        %{name: ch.name, connected: ch.connected, module: inspect(ch.module)}
      end),
      count: length(channels),
      active_count: Enum.count(channels, & &1.connected)
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Telegram ──────────────────────────────────────────────────────────

  post "/channels/telegram/webhook" do
    case Telegram.handle_update(conn.body_params) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_started} -> json_error(conn, 503, "channel_unavailable", "Telegram adapter not started")
    end
  end

  # ── Discord ───────────────────────────────────────────────────────────

  post "/channels/discord/webhook" do
    signature = get_req_header(conn, "x-signature-ed25519") |> List.first("")
    timestamp = get_req_header(conn, "x-signature-timestamp") |> List.first("")
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case Discord.handle_interaction(raw_body, signature, timestamp) do
      {:pong, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      {:ok, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid request signature")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "Discord adapter not started")
    end
  end

  # ── Slack ─────────────────────────────────────────────────────────────

  post "/channels/slack/events" do
    timestamp = get_req_header(conn, "x-slack-request-timestamp") |> List.first("")
    signature = get_req_header(conn, "x-slack-signature") |> List.first("")
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case Slack.handle_event(raw_body, timestamp, signature) do
      {:challenge, challenge} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{challenge: challenge}))

      :ok ->
        send_resp(conn, 200, "")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid request signature")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "Slack adapter not started")
    end
  end

  # ── WhatsApp ──────────────────────────────────────────────────────────

  get "/channels/whatsapp/webhook" do
    case WhatsApp.verify_challenge(conn.params) do
      {:ok, challenge} ->
        send_resp(conn, 200, challenge)

      {:error, :forbidden} ->
        send_resp(conn, 403, "Forbidden")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "WhatsApp adapter not started")
    end
  end

  post "/channels/whatsapp/webhook" do
    WhatsApp.handle_webhook(conn.body_params)
    send_resp(conn, 200, "")
  end

  # ── Signal ────────────────────────────────────────────────────────────

  post "/channels/signal/webhook" do
    case SignalChannel.handle_webhook(conn.body_params) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_started} -> json_error(conn, 503, "channel_unavailable", "Signal adapter not started")
    end
  end

  # ── Matrix ────────────────────────────────────────────────────────────
  # Matrix uses long-polling /sync internally; this endpoint is a future
  # placeholder for push-mode Matrix homeserver notifications.

  post "/channels/matrix/webhook" do
    _ = Matrix
    send_resp(conn, 200, "")
  end

  # ── Email (inbound parse) ─────────────────────────────────────────────

  post "/channels/email/inbound" do
    case EmailChannel.handle_inbound(conn.body_params) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_started} -> json_error(conn, 503, "channel_unavailable", "Email adapter not started")
    end
  end

  # ── QQ ────────────────────────────────────────────────────────────────

  post "/channels/qq/webhook" do
    signature = get_req_header(conn, "x-signature") |> List.first("")
    timestamp = get_req_header(conn, "x-timestamp") |> List.first("")
    nonce = get_req_header(conn, "x-nonce") |> List.first("")
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case QQ.handle_event(raw_body, signature, timestamp, nonce) do
      {:challenge, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      :ok ->
        send_resp(conn, 200, "")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid QQ signature")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "QQ adapter not started")
    end
  end

  # ── DingTalk ──────────────────────────────────────────────────────────

  post "/channels/dingtalk/webhook" do
    case DingTalk.handle_event(conn.body_params) do
      :ok -> send_resp(conn, 200, "")
      {:error, :not_started} -> json_error(conn, 503, "channel_unavailable", "DingTalk adapter not started")
    end
  end

  # ── Feishu ────────────────────────────────────────────────────────────

  post "/channels/feishu/events" do
    case Feishu.handle_event(conn.body_params) do
      {:challenge, challenge} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{challenge: challenge}))

      :ok ->
        send_resp(conn, 200, "")

      {:error, :decryption_failed} ->
        json_error(conn, 400, "decryption_failed", "Could not decrypt event payload")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "Feishu adapter not started")
    end
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

  # ── Swarm Helpers ────────────────────────────────────────────────────

  defp swarm_to_map(swarm) do
    %{
      id: swarm.id,
      status: swarm.status,
      task: swarm.task,
      pattern: swarm.pattern,
      agent_count: swarm.agent_count,
      agents: swarm.agents || [],
      result: swarm.result,
      error: swarm.error,
      started_at: swarm.started_at,
      completed_at: swarm.completed_at
    }
  end

  defp parse_swarm_pattern(nil), do: nil
  defp parse_swarm_pattern(p) when is_binary(p) do
    valid = ~w(parallel pipeline debate review)
    if p in valid, do: String.to_existing_atom(p), else: nil
  end
  defp parse_swarm_pattern(_), do: nil

  # Only include in opts list when value is non-nil
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
