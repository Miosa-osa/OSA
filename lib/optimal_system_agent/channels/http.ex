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
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> put_resp_header("access-control-max-age", "86400")
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

    body =
      Jason.encode!(%{
        status: "ok",
        version: version,
        provider: provider,
        model: model_name
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Onboarding (no auth) ──────────────────────────────────────

  get "/onboarding/status" do
    needs = OptimalSystemAgent.Onboarding.first_run?()
    system_info = OptimalSystemAgent.Onboarding.detect_system()
    providers = OptimalSystemAgent.Onboarding.providers_list()
    templates = OptimalSystemAgent.Onboarding.templates_list()
    machines = OptimalSystemAgent.Onboarding.machines_list()
    channels = OptimalSystemAgent.Onboarding.channels_list()

    body =
      Jason.encode!(%{
        needs_onboarding: needs,
        system_info: system_info,
        providers: providers,
        templates: templates,
        machines: machines,
        channels: channels
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/onboarding/setup" do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)

    case Jason.decode(raw) do
      {:ok, params} ->
        state = %{
          agent_name: Map.get(params, "agent_name", "OSA"),
          user_name: Map.get(params, "user_name"),
          user_context: Map.get(params, "user_context"),
          provider: Map.get(params, "provider", "ollama"),
          model: Map.get(params, "model", "llama3.2:latest"),
          api_key: Map.get(params, "api_key"),
          env_var: Map.get(params, "env_var"),
          machines: Map.get(params, "machines", %{"communication" => false, "productivity" => false, "research" => false}),
          channels_config: Map.get(params, "channels", %{}),
          os_template: Map.get(params, "os_template")
        }

        case OptimalSystemAgent.Onboarding.write_setup(state) do
          :ok ->
            OptimalSystemAgent.Onboarding.apply_config()

            # Reload soul files to pick up new IDENTITY.md/SOUL.md
            try do
              OptimalSystemAgent.Soul.reload()
            rescue
              _ -> :ok
            end

            # Auto-detect Ollama tiers if Ollama selected
            if state.provider == "ollama" do
              try do
                OptimalSystemAgent.Providers.Ollama.auto_detect_model()
                OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
              rescue
                _ -> :ok
              end
            end

            # Connect OS template if specified
            if state.os_template do
              try do
                path = Map.get(state.os_template, "path")

                if is_binary(path) and path != "" do
                  OptimalSystemAgent.OS.Registry.connect(path)
                end
              rescue
                _ -> :ok
              end
            end

            # Run post-setup health checks
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

            body =
              Jason.encode!(%{
                status: "ok",
                provider: state.provider,
                model: state.model,
                checks: checks
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {:error, reason} ->
            body = Jason.encode!(%{error: "setup_failed", details: reason})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, body)
        end

      {:error, _} ->
        body = Jason.encode!(%{error: "invalid_json"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, body)
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
