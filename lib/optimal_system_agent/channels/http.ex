defmodule OptimalSystemAgent.Channels.HTTP do
  @moduledoc """
  HTTP channel adapter — Plug.Router served by Bandit on port 9089.

  This is the API surface that MIOSA SDK clients consume. Symmetrical with
  CLI, Telegram, and other channel adapters — all signals go through the
  same Agent.Loop pipeline.

  Endpoints (v1):
    POST /api/v1/orchestrate           Full ReAct agent loop
    GET  /api/v1/stream/:session_id    SSE event stream
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

  plug(:security_headers)
  plug(:cors_headers)
  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  # ── Security headers ──────────────────────────────────────────────

  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("content-security-policy", "default-src 'none'")
    |> put_resp_header("strict-transport-security", "max-age=31536000; includeSubDomains")
  end

  # ── CORS middleware ────────────────────────────────────────────────

  defp cors_headers(conn, _opts) do
    allowed = Application.get_env(:optimal_system_agent, :cors_allowed_origins, ["*"])
    request_origin = conn |> get_req_header("origin") |> List.first()

    {origin_value, vary?} =
      cond do
        allowed == ["*"] ->
          {"*", false}

        request_origin && request_origin in allowed ->
          {request_origin, true}

        true ->
          {List.first(allowed, "*"), true}
      end

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", origin_value)
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type, authorization, accept, cache-control, x-accel-buffering")
      |> put_resp_header("access-control-max-age", "86400")

    if vary?, do: put_resp_header(conn, "vary", "Origin"), else: conn
  end

  # ── OPTIONS preflight (CORS) ────────────────────────────────────────

  options _ do
    conn
    |> send_resp(204, "")
  end

  # ── Health (no auth) ────────────────────────────────────────────────

  get "/health" do
    provider =
      Application.get_env(:optimal_system_agent, :default_provider, "unknown")
      |> to_string()

    model_name =
      case Application.get_env(:optimal_system_agent, :default_model) do
        nil ->
          # Resolve from provider's default model
          prov = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

          case OptimalSystemAgent.Providers.Registry.provider_info(prov) do
            {:ok, info} -> to_string(info.default_model)
            _ -> to_string(prov)
          end

        m ->
          to_string(m)
      end

    version =
      case Application.spec(:optimal_system_agent, :vsn) do
        nil -> "0.2.5"
        vsn -> to_string(vsn)
      end

    uptime = max(0, System.system_time(:second) - Application.get_env(:optimal_system_agent, :start_time, System.system_time(:second)))

    context_window = OptimalSystemAgent.Providers.Registry.context_window(model_name)

    body =
      Jason.encode!(%{
        status: "ok",
        version: version,
        uptime_seconds: uptime,
        provider: provider,
        model: model_name,
        context_window: context_window
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Onboarding (no auth) ──────────────────────────────────────

  get "/onboarding/status" do
    alias OptimalSystemAgent.Onboarding

    bootstrap_exists = File.exists?(Path.expand("~/.osa/BOOTSTRAP.md"))

    body =
      Jason.encode!(%{
        needs_onboarding: Onboarding.first_run?(),
        needs_bootstrap: bootstrap_exists,
        system_info: Onboarding.detect_system(),
        providers: Onboarding.providers_list(),
        detected: Onboarding.detect_existing()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/onboarding/detect" do
    body = Jason.encode!(OptimalSystemAgent.Onboarding.detect_existing())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/onboarding/models" do
    conn = Plug.Conn.fetch_query_params(conn)
    provider = conn.query_params["provider"] || "ollama_local"
    base_url = conn.query_params["base_url"]
    api_key = conn.query_params["api_key"]

    case OptimalSystemAgent.Onboarding.model_list(provider, base_url: base_url, api_key: api_key) do
      {:ok, models} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{models: models}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{error: "model_fetch_failed", message: reason}))
    end
  end

  post "/onboarding/health-check" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, params} ->
            case OptimalSystemAgent.Onboarding.health_check(params) do
              {:ok, result} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(result))

              {:error, result} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(result))
            end

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, ~s({"error":"invalid_json"}))
        end

      {:more, _partial, conn} ->
        conn |> put_resp_content_type("application/json") |> send_resp(413, ~s({"error":"payload_too_large"}))

      {:error, _reason} ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"read_failed"}))
    end
  end

  post "/onboarding/setup" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, params} ->
            case OptimalSystemAgent.Onboarding.write_setup(params) do
              :ok ->
                # Auto-detect Ollama tiers if Ollama-based provider
                provider = Map.get(params, "provider", "")

                if provider in ["ollama_cloud", "ollama_local", "ollama"] do
                  try do
                    OptimalSystemAgent.Providers.Ollama.auto_detect_model()
                    OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
                  rescue
                    _ -> :ok
                  end
                end

                checks =
                  try do
                    OptimalSystemAgent.Onboarding.doctor_checks()
                    |> Enum.map(fn
                      {:ok, desc} -> %{status: "ok", check: desc}
                      {:error, desc, reason} -> %{status: "error", check: desc, reason: reason}
                    end)
                  rescue
                    _ -> []
                  end

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{
                  status: "ok",
                  provider: Map.get(params, "provider"),
                  model: Map.get(params, "model"),
                  checks: checks
                }))

              {:error, reason} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(500, Jason.encode!(%{error: "setup_failed", details: reason}))
            end

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, ~s({"error":"invalid_json"}))
        end

      {:more, _partial, conn} ->
        conn |> put_resp_content_type("application/json") |> send_resp(413, ~s({"error":"payload_too_large"}))

      {:error, _reason} ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"read_failed"}))
    end
  end

  # ── Survey / waitlist (no auth — anonymous submissions) ─────────────

  post "/api/survey" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, body} ->
            :ets.insert(:osa_survey_responses, {System.unique_integer([:positive]), body, DateTime.utc_now()})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "collected"}))

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "invalid_json"}))
        end

      {:more, _partial, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, Jason.encode!(%{error: "request_too_large"}))

      {:error, reason} ->
        Logger.warning("Channels.HTTP: /api/survey read_body error: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "read_error"}))
    end
  end

  post "/api/waitlist" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, body} ->
            # Waitlist is a lightweight survey with just email + optional source
            attrs = Map.put_new(body, "role", "other")
            :ets.insert(:osa_survey_responses, {System.unique_integer([:positive]), attrs, DateTime.utc_now()})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "collected"}))

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "invalid_json"}))
        end

      {:more, _partial, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, Jason.encode!(%{error: "request_too_large"}))

      {:error, reason} ->
        Logger.warning("Channels.HTTP: /api/waitlist read_body error: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "read_error"}))
    end
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
