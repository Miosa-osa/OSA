defmodule OptimalSystemAgent.Channels.HTTP.API.CommandCenterRoutes do
  @moduledoc """
  Command Center API routes.

  Forwarded prefix: /command-center

  Routes:
    GET  /                          → dashboard summary
    GET  /agents                    → all agents
    GET  /agents/health             → all agents health summary
    GET  /agents/:name/health       → single agent health
    GET  /agents/:name              → agent detail
    GET  /tiers                     → tier breakdown
    GET  /patterns                  → swarm patterns
    GET  /metrics                   → metrics summary
    GET  /sandboxes                 → list sandboxes
    POST /sandboxes                 → provision sandbox
    DELETE /sandboxes/:id           → deprovision sandbox
    GET  /events                    → SSE event stream
    GET  /events/history            → recent event history
    GET  /scheduler                 → scheduler status
    GET  /scheduler/jobs            → list jobs
    POST /scheduler/jobs            → add job
    DELETE /scheduler/jobs/:id      → remove job
    POST /scheduler/jobs/:id/toggle → toggle job enabled
    POST /scheduler/jobs/:id/run    → run job immediately
    GET  /scheduler/triggers        → list triggers
    POST /scheduler/triggers        → add trigger
    DELETE /scheduler/triggers/:id  → remove trigger
    POST /scheduler/triggers/:id/toggle → toggle trigger enabled
    GET  /skills                    → list loaded skills
    POST /skills/reload             → hot-reload skills from disk

  There is deliberately no `/webhooks` group here. Three routes used to call
  `OptimalSystemAgent.Webhooks.Dispatcher`, a module that has never existed in
  this repo, so every request to them raised `UndefinedFunctionError`. Inbound
  webhooks are served by `DataRoutes` at `POST /api/v1/webhooks/:trigger_id`;
  outbound webhook fan-out was never built.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.CommandCenter
  alias OptimalSystemAgent.EventStream
  alias OptimalSystemAgent.Sandbox.Provisioner
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Agent.HealthTracker
  alias OptimalSystemAgent.Tools.Registry, as: ToolRegistry

  plug(:match)
  plug(:dispatch)

  # ── GET / — dashboard summary ──────────────────────────────────────

  get "/" do
    body = Jason.encode!(CommandCenter.dashboard_summary())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /agents — all agents ───────────────────────────────────────

  get "/agents" do
    agents =
      OptimalSystemAgent.Agent.Roster.all()
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&redact_agent_prompt/1)

    body = Jason.encode!(%{agents: agents, count: length(agents)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /agents/health — all agents health summary ─────────────────

  get "/agents/health" do
    agents = HealthTracker.all()
    body = Jason.encode!(%{agents: agents, count: length(agents)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /agents/:name/health — single agent health ─────────────────

  get "/agents/:name/health" do
    case HealthTracker.get(name) do
      {:ok, health} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(health))

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "No health data for agent '#{name}'")
    end
  end

  # ── GET /agents/:name — agent detail ───────────────────────────────

  get "/agents/:name" do
    case CommandCenter.agent_detail(name) do
      {:ok, detail} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(redact_agent_prompt(detail)))

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Agent '#{name}' not found")
    end
  end

  # ── GET /tiers — tier breakdown ────────────────────────────────────

  get "/tiers" do
    body = Jason.encode!(CommandCenter.tier_breakdown())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /patterns — swarm patterns ─────────────────────────────────

  get "/patterns" do
    patterns =
      OptimalSystemAgent.Agent.Orchestrator.Patterns.list_patterns()
      |> Enum.map(fn {name, desc} -> %{name: name, description: desc} end)

    body = Jason.encode!(%{patterns: patterns, count: length(patterns)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /metrics — metrics summary ─────────────────────────────────

  get "/metrics" do
    body = Jason.encode!(CommandCenter.metrics_summary())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /sandboxes — list sandboxes ────────────────────────────────

  get "/sandboxes" do
    body = Jason.encode!(%{sandboxes: [], count: 0})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sandboxes — provision sandbox ────────────────────────────

  post "/sandboxes" do
    with %{"os_id" => os_id} <- conn.body_params do
      template =
        case conn.body_params["template"] do
          t when t in ~w(node python elixir go rust) -> String.to_existing_atom(t)
          _ -> :default
        end

      case Provisioner.provision(os_id, template) do
        {:ok, sprite_id} ->
          body = Jason.encode!(%{status: "provisioned", os_id: os_id, sprite_id: sprite_id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, reason} ->
          json_error(conn, 500, "provision_failed", inspect(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: os_id")
    end
  end

  # ── DELETE /sandboxes/:id — deprovision sandbox ────────────────────

  delete "/sandboxes/:id" do
    case Provisioner.deprovision(id) do
      :ok ->
        body = Jason.encode!(%{status: "deprovisioned", os_id: id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Sandbox '#{id}' not found")

      {:error, reason} ->
        json_error(conn, 500, "deprovision_failed", inspect(reason))
    end
  end

  # ── GET /events — live SSE firehose ────────────────────────────────
  # Streams all command_center events to admin/monitoring clients.

  get "/events" do
    # Subscribe BEFORE send_chunked to avoid race window
    EventStream.subscribe()

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(conn, "event: connected\ndata: {\"channel\": \"command_center\"}\n\n") do
      {:ok, conn} ->
        Logger.debug("[CommandCenter] SSE client connected")
        cc_sse_loop(conn)

      {:error, _} ->
        conn
    end
  end

  # ── GET /events/history — recent event history ─────────────────────
  # Returns the last N events from the in-memory ring-buffer.
  # Query param: limit (default 50, max 100)

  get "/events/history" do
    limit =
      conn.query_params
      |> Map.get("limit", "50")
      |> Integer.parse()
      |> case do
        {n, _} when n > 0 -> min(n, 100)
        _ -> 50
      end

    events = EventStream.event_history()
    events = Enum.take(events, -limit)
    body = Jason.encode!(%{events: events, count: length(events), limit: limit})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /scheduler — overall scheduler status ──────────────────────

  get "/scheduler" do
    try do
      body = Jason.encode!(Scheduler.status())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── GET /scheduler/jobs — list all cron jobs ───────────────────────

  get "/scheduler/jobs" do
    try do
      jobs = Scheduler.list_jobs()
      body = Jason.encode!(%{jobs: jobs, count: length(jobs)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs — create a new cron job ───────────────────

  post "/scheduler/jobs" do
    try do
      case Scheduler.add_job(conn.body_params) do
        {:ok, job} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(job))

        {:error, reason} ->
          json_error(conn, 422, "add_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── DELETE /scheduler/jobs/:id — remove a cron job ─────────────────

  delete "/scheduler/jobs/:id" do
    try do
      case Scheduler.remove_job(id) do
        :ok ->
          body = Jason.encode!(%{status: "removed", id: id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "remove_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs/:id/toggle — enable or disable a job ──────

  post "/scheduler/jobs/:id/toggle" do
    try do
      enabled = conn.body_params["enabled"]

      case Scheduler.toggle_job(id, enabled) do
        {:ok, job} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(job))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "toggle_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs/:id/run — execute a job immediately ───────

  post "/scheduler/jobs/:id/run" do
    try do
      case Scheduler.run_job(id) do
        {:ok, result} ->
          body = Jason.encode!(%{status: "executed", id: id, result: result})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "run_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── GET /scheduler/triggers — list all triggers ─────────────────────

  get "/scheduler/triggers" do
    try do
      triggers = Scheduler.list_triggers()
      body = Jason.encode!(%{triggers: triggers, count: length(triggers)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/triggers — create a new trigger ─────────────────

  post "/scheduler/triggers" do
    try do
      case Scheduler.add_trigger(conn.body_params) do
        {:ok, trigger} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(trigger))

        {:error, reason} ->
          json_error(conn, 422, "add_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── DELETE /scheduler/triggers/:id — remove a trigger ───────────────

  delete "/scheduler/triggers/:id" do
    try do
      case Scheduler.remove_trigger(id) do
        :ok ->
          body = Jason.encode!(%{status: "removed", id: id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Trigger '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "remove_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/triggers/:id/toggle — enable or disable a trigger

  post "/scheduler/triggers/:id/toggle" do
    try do
      enabled = conn.body_params["enabled"]

      case Scheduler.toggle_trigger(id, enabled) do
        {:ok, trigger} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(trigger))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Trigger '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "toggle_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── GET /skills — list all loaded skills ─────────────────────────────

  get "/skills" do
    skills = ToolRegistry.list_skills()

    body =
      Jason.encode!(%{
        skills:
          Enum.map(skills, fn s ->
            %{
              name: s.name,
              description: s.description,
              triggers: s.triggers,
              path: s.path
            }
          end),
        count: length(skills)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /skills/reload — hot-reload skills from disk ─────────────────

  post "/skills/reload" do
    ToolRegistry.reload_skills()

    skills = ToolRegistry.list_skills()

    body = Jason.encode!(%{status: "reloaded", count: length(skills)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Command Center endpoint not found")
  end

  # ── Private ──────────────────────────────────────────────────────────

  # SECURITY: strip system prompt from agent representations before
  # returning them over the API. Prompt leakage is FINDING-01 (Critical).
  defp redact_agent_prompt(agent) when is_map(agent) do
    agent
    |> Map.drop([:prompt, "prompt"])
    |> Map.put(:prompt, "[REDACTED]")
  end

  defp cc_sse_loop(conn) do
    receive do
      {:command_center_event, event} ->
        event_type =
          case event do
            %{type: t} -> t |> to_string() |> String.replace(~r/[\r\n]/, "")
            _ -> "event"
          end

        case Jason.encode(event) do
          {:ok, data} ->
            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                cc_sse_loop(conn)

              {:error, _} ->
                Logger.debug("[CommandCenter] SSE client disconnected")
                conn
            end

          {:error, _} ->
            cc_sse_loop(conn)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> cc_sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end
end
