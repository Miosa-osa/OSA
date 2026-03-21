defmodule OptimalSystemAgent.Channels.HTTP.API do
  @moduledoc """
  Authenticated API router — all endpoints under /api/v1.

  Auth plug runs globally. Channel webhook routes bypass JWT because they
  are forwarded before the auth result halts the conn — platform-specific
  HMAC/challenge verification happens inside ChannelRoutes.

  Sub-router forwarding map:

    /auth        → AuthRoutes        POST /login|logout|refresh
    /channels    → ChannelRoutes     GET /, POST /*/webhook (10 platforms)
    /sessions    → SessionRoutes     GET|POST /, GET|DELETE /:id, GET /:id/messages, POST /:id/cancel
    /fleet       → FleetRoutes       POST /register|heartbeat|dispatch, GET /agents|/:id
    /orchestrate → OrchestrationRoutes  POST /|/complex, GET /tasks, GET /:id/progress
    /swarm       → OrchestrationRoutes  POST /launch, GET /|/:id, DELETE /:id
    /debate      → DebateRoutes       POST / (multi-agent debate + synthesis)
    /stream      → AgentRoutes       GET /tui_output (SSE alias), GET /:session_id  (SSE)
    /tui         → TuiRoutes         GET /output (SSE), POST /input
    /tools       → ToolRoutes        GET /, POST /:name/execute
    /skills      → ToolRoutes        GET /, POST /create
    /commands    → ToolRoutes        GET /, POST /execute
    /memory      → DataRoutes        POST /, GET /recall, GET /search
    /models      → DataRoutes        GET /, POST /switch
    /analytics   → DataRoutes        GET /
    /scheduler   → DataRoutes        GET /jobs, POST /reload
    /webhooks    → DataRoutes        POST /:trigger_id
    /machines    → DataRoutes        GET /
    /events      → ProtocolRoutes    POST /, GET /stream
    /oscp        → ProtocolRoutes    POST /
    /tasks       → ProtocolRoutes    GET /history
    /command-center → CommandCenterRoutes  GET /|/agents|/tiers|/patterns|/metrics|/events, POST /sandboxes
    /workspace   → WorkspaceRoutes    GET / (cwd, git status, git log, directory listing)
    /workspaces  → CanopyRoutes      GET|POST /, GET|PATCH|DELETE /:id, POST /:id/activate, GET /:id/agents|skills|config
    /agents      → AgentManagementRoutes  GET /, GET /hierarchy, GET|DELETE /:id, POST /:id/pause|resume
    /settings    → SettingsRoutes    GET|PATCH /
    /providers   → ProviderRoutes    GET /, POST /:slug/connect, DELETE /:slug
    /cost        → CostRoutes        GET /, GET /by-agent, GET /by-model, GET /events, GET /budgets, PUT /budgets/:name
    /dashboard   → DashboardRoutes   GET /
    /classify    → inline            POST / (signal classification)
    /config      → ConfigRoutes      GET /revisions/:type/:id, GET /revisions/:type/:id/:n, POST /revisions/:type/:id/rollback, GET /revisions/:type/:id/diff
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Channels.HTTP.Auth
  alias OptimalSystemAgent.Channels.HTTP.API
  alias OptimalSystemAgent.Signal.Classifier

  # ── Global error handler ────────────────────────────────────────────

  @impl Plug
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e ->
      Logger.error("[API] Unhandled exception: #{Exception.message(e)}",
        exception: Exception.format(:error, e, __STACKTRACE__)
      )

      body = safe_json_encode(%{error: "internal_error", details: Exception.message(e)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, body)
  end

  plug :cors
  plug OptimalSystemAgent.Channels.HTTP.RateLimiter
  plug :validate_content_type
  plug :authenticate
  plug OptimalSystemAgent.Channels.HTTP.Integrity
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000

  plug :dispatch

  # ── Auth (no JWT required — forwarded before authenticate would halt) ─
  forward "/auth", to: API.AuthRoutes

  # ── Channel webhooks (platform-specific auth, not JWT) ───────────────
  forward "/channels", to: API.ChannelRoutes

  # ── Sessions ─────────────────────────────────────────────────────────
  forward "/sessions", to: API.SessionRoutes

  # ── Agent SSE stream ─────────────────────────────────────────────────
  forward "/stream", to: API.AgentRoutes

  # ── Agent introspection
  forward "/agent", to: API.AgentStateRoutes

  # ── Orchestrate (Phase 0: direct agent loop bypass) ─────────────────
  forward "/orchestrate", to: API.OrchestrateRoutes

  # ── Swarm launch / status ─────────────────────────────────────────────
  forward "/swarm", to: API.OrchestrateRoutes

  # ── Tools, skills, commands ──────────────────────────────────────────
  forward "/tools", to: API.ToolRoutes
  forward "/skills", to: API.ToolRoutes
  forward "/commands", to: API.ToolRoutes

  # ── Scheduled Tasks ─────────────────────────────────────────────────
  forward "/scheduled-tasks", to: API.SchedulerRoutes

  # ── Data ─────────────────────────────────────────────────────────────
  forward "/memory", to: API.DataRoutes
  forward "/models", to: API.DataRoutes
  forward "/analytics", to: API.DataRoutes
  forward "/scheduler", to: API.DataRoutes
  forward "/machines", to: API.DataRoutes

  # ── Workspace introspection ───────────────────────────────────────────
  forward "/workspace", to: API.WorkspaceRoutes

  # ── Canopy workspaces (CRUD + .canopy/ init + agent/skill discovery) ─
  forward "/workspaces", to: API.CanopyRoutes

  # ── Agent management (definitions, hierarchy, lifecycle) ─────────────
  forward "/agents", to: API.AgentManagementRoutes

  # ── Settings (read/write ~/.osa/config.json) ─────────────────────────
  forward "/settings", to: API.SettingsRoutes

  # ── Provider management (list, connect, disconnect) ──────────────────
  forward "/providers", to: API.ProviderRoutes

  # ── Cost / budget summary ─────────────────────────────────────────────
  forward "/cost", to: API.CostRoutes
  forward "/costs", to: API.CostRoutes

  # ── Projects / goals ────────────────────────────────────────────────
  forward "/projects", to: API.ProjectRoutes

  # ── Issues ──────────────────────────────────────────────────────────
  forward "/issues", to: API.IssueRoutes

  # ── Approvals ──────────────────────────────────────────────────────
  forward "/approvals", to: API.ApprovalRoutes

  # ── Dashboard (aggregated overview) ──────────────────────────────────
  forward "/dashboard", to: API.DashboardRoutes

  # ── Config revisions ─────────────────────────────────────────────────
  forward "/config", to: API.ConfigRoutes

  # ── Signal classification (inline — single endpoint) ─────────────────
  post "/classify" do
    with %{"message" => message} when is_binary(message) and message != "" <- conn.body_params do
      channel = conn.body_params["channel"] || "http"
      channel_atom = safe_channel_atom(channel)

      signal = Classifier.classify(message, channel_atom)

      body =
        Jason.encode!(%{
          signal: %{
            mode: signal.mode,
            genre: signal.genre,
            type: signal.type,
            format: signal.format,
            weight: signal.weight
          }
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    else
      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: message")
    end
  end

  # ── Catch-all ────────────────────────────────────────────────────────
  match _ do
    body = Jason.encode!(%{error: "not_found", details: "Endpoint not found"})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, body)
  end

  # ── JWT Authentication Plug ─────────────────────────────────────────
  # Auth routes and channel webhook routes bypass JWT.

  @known_channels ~w(cli http tui telegram discord slack whatsapp signal matrix email qq dingtalk feishu)

  defp safe_channel_atom(ch) when is_binary(ch) do
    if ch in @known_channels, do: String.to_existing_atom(ch), else: :http
  end

  defp safe_json_encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> Jason.encode!(%{error: "internal_error"})
    end
  end

  # ── CORS Plug ───────────────────────────────────────────────────────
  defp cors(%{method: "OPTIONS"} = conn, _opts) do
    origin = Application.get_env(:optimal_system_agent, :cors_origin, "*")

    conn
    |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
    |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> Plug.Conn.put_resp_header("access-control-allow-headers", "authorization, content-type, accept, cache-control, x-accel-buffering")
    |> Plug.Conn.put_resp_header("access-control-max-age", "86400")
    |> Plug.Conn.send_resp(204, "")
    |> Plug.Conn.halt()
  end

  defp cors(conn, _opts) do
    origin = Application.get_env(:optimal_system_agent, :cors_origin, "*")

    conn
    |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
    |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
    |> Plug.Conn.put_resp_header("access-control-allow-headers", "authorization, content-type, accept, cache-control, x-accel-buffering")
  end

  # ── Content-Type validation for write methods ─────────────────────
  defp validate_content_type(%{method: method} = conn, _opts) when method in ["POST", "PUT", "PATCH"] do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct | _] ->
        if String.starts_with?(ct, "application/json") do
          conn
        else
          body = safe_json_encode(%{error: "unsupported_media_type", details: "Content-Type must be application/json"})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(415, body)
          |> Plug.Conn.halt()
        end

      [] ->
        # Allow missing content-type for empty bodies
        conn
    end
  end

  defp validate_content_type(conn, _opts), do: conn

  defp authenticate(%{request_path: "/api/v1/auth/" <> _} = conn, _opts), do: conn
  defp authenticate(%{request_path: "/api/v1/channels/" <> _} = conn, _opts), do: conn
  defp authenticate(%{request_path: "/api/v1/platform/auth/" <> _} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Auth.verify_token(token) do
          {:ok, claims} ->
            conn
            |> assign(:user_id, claims["user_id"])
            |> assign(:workspace_id, claims["workspace_id"])
            |> assign(:claims, claims)

          {:error, reason} ->
            if Application.get_env(:optimal_system_agent, :require_auth, false) do
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "INVALID_TOKEN"}))
              |> halt()
            else
              Logger.warning("Invalid/expired token ignored (require_auth=false): #{inspect(reason)}")

              conn
              |> assign(:user_id, "anonymous")
              |> assign(:workspace_id, nil)
              |> assign(:claims, %{})
            end
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
end
