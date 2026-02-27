defmodule OptimalSystemAgent.Channels.HTTP do
  @moduledoc """
  HTTP channel adapter — Plug.Router served by Bandit on port 8089.

  This is the API surface that MIOSA SDK clients consume. Symmetrical with
  CLI, Telegram, and other channel adapters — all signals go through the
  same Agent.Loop and Signal.Classifier pipeline.

  Endpoints (v1):
    POST /api/v1/orchestrate           Full ReAct agent loop
    GET  /api/v1/stream/:session_id    SSE event stream
    POST /api/v1/classify              Signal classification
    GET  /api/v1/tools                 List executable tools
    POST /api/v1/tools/:name/execute   Execute a tool by name
    GET  /api/v1/skills                List SKILL.md prompt definitions
    POST /api/v1/skills/create         Create a new SKILL.md
    POST /api/v1/orchestrate/complex   Multi-agent orchestration
    POST /api/v1/swarm/launch          Launch agent swarm
    POST /api/v1/memory                Save to memory
    GET  /api/v1/memory/recall         Recall memory
    GET  /api/v1/machines              List active machines
    POST /api/v1/fleet/*               Fleet management (register, heartbeat, dispatch)
    POST /api/v1/channels/*/webhook    Channel adapter webhooks
    GET  /health                       Health check (no auth)

  Auth: HS256 JWT via Authorization: Bearer <token>
  Transport: HTTP/1.1 + SSE via Plug/Bandit
  """
  use Plug.Router
  require Logger

  alias OptimalSystemAgent.Machines

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  # ── Health (no auth) ────────────────────────────────────────────────

  get "/health" do
    body =
      Jason.encode!(%{
        status: "ok",
        version: Application.spec(:optimal_system_agent, :vsn) |> to_string(),
        uptime_seconds: System.monotonic_time(:second),
        machines: Machines.active(),
        provider: Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── All /api routes require JWT ─────────────────────────────────────

  forward("/api/v1", to: OptimalSystemAgent.Channels.HTTP.API)

  # ── Catch-all ───────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end
