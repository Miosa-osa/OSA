defmodule OptimalSystemAgent.Channels.HTTP.API do
  @moduledoc """
  Authenticated API routes — all endpoints under /api/v1.

  Every route goes through JWT verification first. In dev mode (require_auth: false),
  unauthenticated requests are allowed with an "anonymous" user_id.

  Agent endpoints:
    POST   /orchestrate                    — Process message through agent loop
    GET    /stream/:session_id             — SSE event stream for a session
    POST   /classify                       — Signal classification only

  Tool & skill endpoints:
    GET    /tools                          — List executable tools
    POST   /tools/:name/execute            — Execute a tool by name
    GET    /skills                         — List SKILL.md prompt definitions
    POST   /skills/create                  — Create a new SKILL.md file

  Command endpoints:
    GET    /commands                       — List available slash commands
    POST   /commands/execute               — Execute a slash command

  Orchestration endpoints:
    POST   /orchestrate/complex            — Launch multi-agent orchestrated task
    GET    /orchestrate/:task_id/progress   — Real-time progress for orchestrated task
    GET    /orchestrate/tasks              — List all orchestrated tasks

  Swarm endpoints:
    POST   /swarm/launch                   — Launch a new multi-agent swarm
    GET    /swarm                          — List all swarms
    GET    /swarm/:id                      — Get swarm status and result
    DELETE /swarm/:id                      — Cancel a running swarm

  Memory endpoints:
    POST   /memory                         — Save to memory
    GET    /memory/recall                  — Recall memory

  Scheduler endpoints:
    GET    /scheduler/jobs                 — List scheduled jobs
    POST   /scheduler/reload               — Reload scheduler from config

  Fleet endpoints:
    POST   /fleet/register                 — Self-register an edge agent
    GET    /fleet/:agent_id/instructions    — Poll for pending tasks (OSCP CloudEvent)
    POST   /fleet/heartbeat                — Forward agent heartbeat
    GET    /fleet/agents                   — List all registered agents
    GET    /fleet/:agent_id                — Get single agent details
    POST   /fleet/dispatch                 — Dispatch instruction to agent

  Event endpoints:
    POST   /events                         — Publish an event to the bus
    GET    /events/stream                  — SSE stream for all events

  Channel webhooks:
    GET    /channels                        — List active channel adapters
    POST   /channels/telegram/webhook       — Telegram bot webhook
    POST   /channels/discord/webhook        — Discord bot webhook
    POST   /channels/slack/events           — Slack event subscription
    GET    /channels/whatsapp/webhook       — WhatsApp verification
    POST   /channels/whatsapp/webhook       — WhatsApp message webhook
    POST   /channels/signal/webhook         — Signal messenger webhook
    POST   /channels/matrix/webhook         — Matrix room webhook
    POST   /channels/email/inbound          — Inbound email webhook
    POST   /channels/qq/webhook             — QQ bot webhook
    POST   /channels/dingtalk/webhook       — DingTalk bot webhook
    POST   /channels/feishu/events          — Feishu/Lark event webhook

  Other endpoints:
    GET    /machines                        — List active machines
    POST   /webhooks/:trigger_id            — Trigger a webhook
    POST   /oscp                            — OSCP protocol endpoint
    GET    /tasks/history                   — Task execution history
  """
  use Plug.Router
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Commands
  alias OptimalSystemAgent.Machines
  alias OptimalSystemAgent.Channels.HTTP.Auth
  alias OptimalSystemAgent.Events.Bus
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
  alias OptimalSystemAgent.Protocol.CloudEvent
  alias OptimalSystemAgent.Protocol.OSCP
  alias OptimalSystemAgent.Fleet.Registry, as: Fleet
  alias OptimalSystemAgent.Agent.TaskQueue

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

  plug(:authenticate)
  plug(OptimalSystemAgent.Channels.HTTP.Integrity)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  # ── POST /orchestrate ───────────────────────────────────────────────

  post "/orchestrate" do
    with %{"input" => input} <- conn.body_params do
      user_id = conn.body_params["user_id"] || conn.assigns[:user_id]
      session_id = conn.body_params["session_id"] || generate_session_id()
      _workspace_id = conn.body_params["workspace_id"]

      start_time = System.monotonic_time(:millisecond)

      # Ensure an agent loop exists for this session
      Session.ensure_loop(session_id, user_id, :http)

      # Process through the agent loop (same pipeline as CLI)
      case Loop.process_message(session_id, input) do
        {:ok, response} ->
          execution_ms = System.monotonic_time(:millisecond) - start_time
          signal = Classifier.classify(input, :http)

          body =
            Jason.encode!(%{
              session_id: session_id,
              output: response,
              signal: signal_to_map(signal),
              tools_used: [],
              iteration_count: 0,
              execution_ms: execution_ms,
              metadata: %{}
            })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:filtered, signal} ->
          body =
            Jason.encode!(%{
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
        {:ok, conn} =
          chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

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

  # ── GET /tools ──────────────────────────────────────────────────────

  get "/tools" do
    tools = Tools.list_tools()

    body =
      Jason.encode!(%{
        tools: tools,
        count: length(tools)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /tools/:name/execute ─────────────────────────────────────

  post "/tools/:name/execute" do
    tool_name = conn.params["name"]
    arguments = conn.body_params["arguments"] || %{}

    case Tools.execute(tool_name, arguments) do
      {:ok, result} ->
        body =
          Jason.encode!(%{
            tool: tool_name,
            status: "completed",
            result: result
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 422, "tool_error", to_string(reason))
    end
  end

  # ── GET /skills ────────────────────────────────────────────────────

  get "/skills" do
    skills = Tools.load_skill_definitions()

    summaries =
      Enum.map(skills, &Map.take(&1, [:name, :description, :category, :triggers, :priority]))

    body = Jason.encode!(%{skills: summaries, count: length(summaries)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /commands ─────────────────────────────────────────────────────

  get "/commands" do
    commands =
      Commands.list_commands()
      |> Enum.map(fn {name, description} -> %{name: name, description: description} end)

    body = Jason.encode!(%{commands: commands, count: length(commands)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /commands/execute ────────────────────────────────────────────

  post "/commands/execute" do
    with %{"command" => command} when is_binary(command) <- conn.body_params do
      arg = conn.body_params["arg"] || ""
      session_id = conn.body_params["session_id"] || "http-#{:erlang.unique_integer([:positive])}"

      input = if arg == "", do: command, else: "#{command} #{arg}"

      {kind, output, action} =
        case Commands.execute(input, session_id) do
          {:command, text} -> {"text", text, ""}
          {:prompt, text} -> {"prompt", text, ""}
          {:action, act, text} -> {"action", text, inspect(act)}
          :unknown -> {"error", "Unknown command: #{command}", ""}
        end

      body = Jason.encode!(%{kind: kind, output: output, action: action})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: command")
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

    body =
      Jason.encode!(%{
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

    body =
      Jason.encode!(%{
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

    body =
      Jason.encode!(%{
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
      blocking = conn.body_params["blocking"] == true

      case TaskOrchestrator.execute(task, session_id, strategy: strategy) do
        {:ok, task_id} ->
          if blocking do
            # Block until complete (backward compat for clients that expect sync response)
            case await_orchestration_http(task_id, 300_000) do
              {:ok, synthesis} ->
                body =
                  Jason.encode!(%{
                    task_id: task_id,
                    status: "completed",
                    synthesis: synthesis,
                    session_id: session_id
                  })

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, body)

              {:error, reason} ->
                json_error(conn, 504, "orchestration_timeout", to_string(reason))
            end
          else
            # Non-blocking: return 202, client polls progress endpoint
            body =
              Jason.encode!(%{
                task_id: task_id,
                status: "running",
                session_id: session_id
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(202, body)
          end

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
    active_count = Enum.count(tasks, &(&1.status == :running))

    body =
      Jason.encode!(%{
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
          body =
            Jason.encode!(%{
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
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Missing required fields: name, description, instructions"
        )
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

          body =
            Jason.encode!(%{
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

        body =
          Jason.encode!(%{
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

  # ── CloudEvents ─────────────────────────────────────────────────────

  post "/events" do
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

  get "/events/stream" do
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

  # ── Fleet Management ───────────────────────────────────────────────

  post "/fleet/heartbeat" do
    with %{"agent_id" => agent_id} <- conn.body_params do
      metrics = Map.drop(conn.body_params, ["agent_id"])

      try do
        Fleet.heartbeat(agent_id, metrics)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "ok"}))
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_id")
    end
  end

  get "/fleet/agents" do
    try do
      agents = Fleet.list_agents()

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{agents: agents, count: length(agents)}))
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  post "/fleet/register" do
    with %{"agent_id" => agent_id} when is_binary(agent_id) and agent_id != "" <-
           conn.body_params do
      capabilities = conn.body_params["capabilities"] || []

      try do
        case Fleet.register_agent(agent_id, capabilities) do
          {:ok, _pid} ->
            body =
              Jason.encode!(%{
                status: "registered",
                agent_id: agent_id,
                capabilities: capabilities
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, body)

          {:error, :already_registered} ->
            json_error(conn, 409, "conflict", "Agent #{agent_id} is already registered")

          {:error, reason} ->
            json_error(conn, 500, "registration_error", inspect(reason))
        end
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_id")
    end
  end

  get "/fleet/:agent_id/instructions" do
    agent_id = conn.params["agent_id"]

    try do
      case TaskQueue.lease(agent_id) do
        {:ok, task} ->
          event = OSCP.instruction(agent_id, task.task_id, task.payload,
            priority: Map.get(task, :priority, 0),
            lease_ms: Map.get(task, :lease_ms, 300_000)
          )

          {:ok, json} = OSCP.encode(event)

          conn
          |> put_resp_content_type("application/cloudevents+json")
          |> send_resp(200, json)

        :empty ->
          send_resp(conn, 204, "")
      end
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  get "/fleet/:agent_id" do
    agent_id = conn.params["agent_id"]

    try do
      case Fleet.get_agent(agent_id) do
        {:ok, agent} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(agent))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Agent #{agent_id} not found")
      end
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  post "/fleet/dispatch" do
    with %{"agent_id" => agent_id, "instruction" => instruction} <- conn.body_params do
      try do
        task_id = "fleet_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
        OptimalSystemAgent.Agent.TaskQueue.enqueue(task_id, agent_id, %{instruction: instruction})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{status: "dispatched", task_id: task_id}))
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing: agent_id, instruction")
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

    body =
      Jason.encode!(%{
        channels:
          Enum.map(channels, fn ch ->
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
    secret = Application.get_env(:optimal_system_agent, :telegram_webhook_secret)

    case verify_telegram_signature(conn, secret) do
      :ok ->
        case Telegram.handle_update(conn.body_params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, :not_started} ->
            json_error(conn, 503, "channel_unavailable", "Telegram adapter not started")
        end

      {:error, :no_secret} ->
        Logger.warning("Telegram webhook rejected: telegram_webhook_secret is not configured")
        json_error(conn, 401, "unauthorized", "Webhook secret not configured")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")
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
    app_secret = Application.get_env(:optimal_system_agent, :whatsapp_app_secret)
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case verify_whatsapp_signature(conn, raw_body, app_secret) do
      :ok ->
        WhatsApp.handle_webhook(conn.body_params)
        send_resp(conn, 200, "")

      {:error, :no_secret} ->
        Logger.warning("WhatsApp webhook rejected: whatsapp_app_secret is not configured")
        json_error(conn, 401, "unauthorized", "Webhook secret not configured")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")
    end
  end

  # ── Signal ────────────────────────────────────────────────────────────

  post "/channels/signal/webhook" do
    case SignalChannel.handle_webhook(conn.body_params) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "Signal adapter not started")
    end
  end

  # ── Matrix ────────────────────────────────────────────────────────────
  # Matrix uses long-polling /sync internally; this endpoint is a future
  # placeholder for push-mode Matrix homeserver notifications.
  # TODO: Add signature verification when Matrix push gateway support is implemented.

  post "/channels/matrix/webhook" do
    _ = Matrix
    send_resp(conn, 200, "")
  end

  # ── Email (inbound parse) ─────────────────────────────────────────────

  post "/channels/email/inbound" do
    secret = Application.get_env(:optimal_system_agent, :email_webhook_secret)

    case verify_email_signature(conn, secret) do
      :ok ->
        case EmailChannel.handle_inbound(conn.body_params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, :not_started} ->
            json_error(conn, 503, "channel_unavailable", "Email adapter not started")
        end

      {:error, :no_secret} ->
        Logger.warning("Email inbound webhook rejected: email_webhook_secret is not configured")
        json_error(conn, 401, "unauthorized", "Webhook secret not configured")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")
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
    secret = Application.get_env(:optimal_system_agent, :dingtalk_secret)
    timestamp = get_req_header(conn, "timestamp") |> List.first("")
    sign = conn.params["sign"] || ""

    case verify_dingtalk_signature(timestamp, sign, secret) do
      :ok ->
        case DingTalk.handle_event(conn.body_params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, :not_started} ->
            json_error(conn, 503, "channel_unavailable", "DingTalk adapter not started")
        end

      {:error, :no_secret} ->
        Logger.warning("DingTalk webhook rejected: dingtalk_secret is not configured")
        json_error(conn, 401, "unauthorized", "Webhook secret not configured")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")
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

  # ── OSCP Protocol Endpoint ──────────────────────────────────────────
  #
  # Accepts OSCP-typed CloudEvents. Routes to the appropriate subsystem:
  #   oscp.heartbeat   → Fleet.heartbeat
  #   oscp.instruction → TaskQueue.enqueue
  #   oscp.result      → TaskQueue.complete/fail
  #   oscp.signal      → Bus.emit (generic)

  post "/oscp" do
    json_body = Jason.encode!(conn.body_params)

    case OSCP.decode(json_body) do
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

  # ── Task History ───────────────────────────────────────────────────
  #
  # Query completed/failed tasks from the database.
  # Query params: agent_id, status, limit (default 50)

  get "/tasks/history" do
    opts =
      []
      |> maybe_put(:agent_id, conn.params["agent_id"])
      |> maybe_put(:status, parse_task_status(conn.params["status"]))
      |> maybe_put(:limit, parse_int(conn.params["limit"]))

    tasks = TaskQueue.list_history(opts)

    body = Jason.encode!(%{tasks: tasks, count: length(tasks)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Auth ────────────────────────────────────────────────────────────

  post "/auth/login" do
    user_id =
      get_in(conn.body_params, ["user_id"]) ||
        "tui_#{System.unique_integer([:positive])}"

    token = Auth.generate_token(%{"user_id" => user_id})
    refresh = Auth.generate_refresh_token(%{"user_id" => user_id})

    body =
      Jason.encode!(%{
        "token" => token,
        "refresh_token" => refresh,
        "expires_in" => 900
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/auth/logout" do
    # Acknowledge logout — stateless JWT, nothing to invalidate server-side
    body = Jason.encode!(%{"ok" => true})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/auth/refresh" do
    refresh_token = get_in(conn.body_params, ["refresh_token"]) || ""

    case Auth.refresh(refresh_token) do
      {:ok, tokens} ->
        body =
          Jason.encode!(%{
            "token" => tokens.token,
            "refresh_token" => tokens.refresh_token,
            "expires_in" => tokens.expires_in
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        body =
          Jason.encode!(%{"error" => "refresh_failed", "details" => to_string(reason)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, body)
    end
  end

  # ── Catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end

  # ── JWT Authentication Plug ─────────────────────────────────────────

  defp authenticate(%{request_path: "/api/v1/auth/" <> _} = conn, _opts), do: conn

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

  defp validate_session_owner(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] ->
        cond do
          # Anonymous / dev-mode requests can access any session
          user_id == "anonymous" -> :ok
          # Owner match — access granted
          owner == user_id -> :ok
          # Registered session but wrong owner — unauthorised
          true ->
            Logger.warning(
              "[API] Session ownership mismatch: session=#{session_id} owner=#{inspect(owner)} requester=#{inspect(user_id)}"
            )

            {:error, :not_found}
        end

      _ ->
        # Session doesn't exist yet — allow SSE to connect and wait.
        # The TUI creates the session_id client-side and connects SSE before
        # the first orchestrate call registers the session. PubSub subscription
        # is safe regardless — events will flow once the session is created.
        if user_id == "anonymous" do
          :ok
        else
          {:error, :not_found}
        end
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

  # ── Helpers ─────────────────────────────────────────────────────────

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

  # Poll orchestrator until task completes or timeout (for blocking HTTP callers)
  defp await_orchestration_http(task_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_orchestration_http(task_id, deadline)
  end

  defp do_await_orchestration_http(task_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "Orchestration timed out"}
    else
      case TaskOrchestrator.progress(task_id) do
        {:ok, %{status: :completed, synthesis: synthesis}} when is_binary(synthesis) ->
          {:ok, synthesis}

        {:ok, %{status: :completed}} ->
          {:ok, "Orchestration completed."}

        {:ok, %{status: _}} ->
          Process.sleep(500)
          do_await_orchestration_http(task_id, deadline)

        {:error, :not_found} ->
          {:error, "Task not found"}
      end
    end
  end

  # Only include in opts list when value is non-nil
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ── Webhook Signature Verification Helpers ───────────────────────────
  #
  # Each helper returns:
  #   :ok                       — signature valid
  #   {:error, :no_secret}      — config key is nil; request must be rejected
  #   {:error, :invalid_signature} — HMAC/header mismatch

  # Telegram: compare x-telegram-bot-api-secret-token header against config secret.
  defp verify_telegram_signature(_conn, nil), do: {:error, :no_secret}

  defp verify_telegram_signature(conn, expected_secret) do
    provided = get_req_header(conn, "x-telegram-bot-api-secret-token") |> List.first("")

    if Plug.Crypto.secure_compare(provided, expected_secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  # WhatsApp: verify x-hub-signature-256 header (Meta webhook pattern).
  # Header format: "sha256=<hex_digest>"
  defp verify_whatsapp_signature(_conn, _raw_body, nil), do: {:error, :no_secret}

  defp verify_whatsapp_signature(conn, raw_body, app_secret) do
    header = get_req_header(conn, "x-hub-signature-256") |> List.first("")
    expected_hex = Base.encode16(:crypto.mac(:hmac, :sha256, app_secret, raw_body), case: :lower)
    expected = "sha256=" <> expected_hex

    if Plug.Crypto.secure_compare(header, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  # DingTalk: verify sign query param using HMAC-SHA256 over "<timestamp>\n<secret>".
  # DingTalk sign = Base64( HMAC-SHA256( "<timestamp>\n<secret>", secret ) )
  defp verify_dingtalk_signature(_timestamp, _sign, nil), do: {:error, :no_secret}

  defp verify_dingtalk_signature(timestamp, sign, secret) do
    string_to_sign = "#{timestamp}\n#{secret}"
    expected = :crypto.mac(:hmac, :sha256, secret, string_to_sign) |> Base.encode64()

    if Plug.Crypto.secure_compare(sign, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  # ── OSCP Routing ───────────────────────────────────────────────────

  defp route_oscp_event(%CloudEvent{type: "oscp.heartbeat"} = event) do
    agent_id = event.data["agent_id"] || event.data[:agent_id] || "unknown"
    metrics = Map.drop(event.data, ["agent_id", :agent_id])

    try do
      Fleet.heartbeat(agent_id, metrics)
    catch
      :exit, _ -> Logger.warning("[API] Fleet unavailable for heartbeat from #{agent_id}")
    end
  end

  defp route_oscp_event(%CloudEvent{type: "oscp.instruction"} = event) do
    task_id = event.data["task_id"] || event.data[:task_id]
    agent_id = event.data["agent_id"] || event.data[:agent_id]
    payload = event.data["payload"] || event.data[:payload] || %{}

    if task_id && agent_id do
      TaskQueue.enqueue(task_id, agent_id, payload)
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
        TaskQueue.fail(task_id, error)

      true ->
        output = event.data["output"] || event.data[:output] || %{}
        TaskQueue.complete(task_id, output)
    end
  end

  defp route_oscp_event(%CloudEvent{type: "oscp.signal"} = event) do
    Bus.emit(:system_event, OSCP.to_bus_event(event))
  end

  defp route_oscp_event(%CloudEvent{} = event) do
    Logger.warning("[API] Unknown OSCP type: #{event.type}")
  end

  defp parse_task_status(nil), do: nil
  defp parse_task_status("completed"), do: :completed
  defp parse_task_status("failed"), do: :failed
  defp parse_task_status(_), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  # Email inbound: compare x-webhook-secret header against config secret.
  defp verify_email_signature(_conn, nil), do: {:error, :no_secret}

  defp verify_email_signature(conn, expected_secret) do
    provided = get_req_header(conn, "x-webhook-secret") |> List.first("")

    if Plug.Crypto.secure_compare(provided, expected_secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
