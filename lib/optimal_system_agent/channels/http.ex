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
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:"
    )
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
      |> put_resp_header(
        "access-control-allow-headers",
        "content-type, authorization, accept, cache-control, x-accel-buffering"
      )
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
    # Provider/model resolution lives in Runtime.Identity, NOT inline here, so
    # the string on the TUI status bar (fed by this response) and the answer the
    # agent gives when asked "what model are you" are the same call. They used to
    # be independent: the bar read /health while the agent grepped config files,
    # guessed llama3.2, and saved the guess to memory as fact.
    provider =
      Application.get_env(:optimal_system_agent, :default_provider, "unknown")
      |> to_string()

    model_name = OptimalSystemAgent.Runtime.Identity.model()

    # Single source of truth: OSA_VERSION (CI-stamped) → app spec → VERSION file.
    # Never a hardcoded literal, so a tagged release always reports its real tag.
    version = OptimalSystemAgent.ReleaseNotes.current_version()

    uptime =
      max(
        0,
        System.system_time(:second) -
          Application.get_env(:optimal_system_agent, :start_time, System.system_time(:second))
      )

    # Seed value for the TUI's "N% ctx" meter (handle_actions.rs only calls
    # set_context when this field is present). It MUST be the model's real
    # usable window or nothing at all: `Registry.context_window/1` would happily
    # return the 128k config default for a model nobody knows, and the meter
    # would then divide real usage by a fabricated denominator and show a
    # confidently wrong percentage. `effective_context_window_info/2` says
    # `:unknown` instead, and a null here leaves context_max at 0, where the TUI
    # already degrades to tokens-only with no percentage.
    provider_atom = provider_atom_for_health(provider)

    context_window =
      try do
        case OptimalSystemAgent.Providers.Registry.effective_context_window_info(
               model_name,
               provider_atom
             ) do
          {:ok, cw} -> cw
          :unknown -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    # Active reasoning/effort level (:fast | :medium | :high | :xhigh | :ultra). Settings
    # cascade resolves session → local → project → user → app default.
    effort =
      try do
        OptimalSystemAgent.Agent.Effort.current() |> to_string()
      rescue
        _ -> "medium"
      catch
        :exit, _ -> "medium"
      end

    # Billing / budget snapshot. OSA has no subscription/plan concept in code,
    # so `subscription` is always nil — the only spend model is the local
    # Budget GenServer (daily/monthly USD spend + limits). Returns nil entirely
    # if the Budget process is unavailable.
    billing = health_billing(provider, model_name)

    body =
      Jason.encode!(%{
        status: "ok",
        version: version,
        uptime_seconds: uptime,
        provider: provider,
        model: model_name,
        context_window: context_window,
        effort: effort,
        # TUI presentation config from ~/.osa/config.toml [tui] (theme/verbosity).
        # This is the backend config surface the TUI reads at startup; the getters
        # fall back to the documented defaults ("dark" / "normal") when unset.
        tui: %{
          theme: OptimalSystemAgent.ConfigFile.tui_theme(),
          verbosity: OptimalSystemAgent.ConfigFile.tui_verbosity()
        },
        billing: billing,
        # Cached "update available" signal (CC/Codex parity: understated
        # notice, never auto-install). Read-only app-env lookup — no git/network
        # on the /health path. `available: false` on source/dev builds, when the
        # checker hasn't run, or on any failure. Drives the TUI's one-time
        # startup notice + the status-bar `⬆ vX` chip; the user runs /update.
        update: OptimalSystemAgent.System.UpdateChecker.health_update()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Onboarding ─────────────────────────────────────────────────────
  #
  # Security model:
  #   - GET /onboarding/status and GET /onboarding/detect are always open
  #     (they reveal nothing an attacker couldn't infer, and the TUI needs
  #     them before a token exists).
  #   - Once setup is complete (first_run?/0 returns false), ALL write
  #     endpoints and the model/health-check probing endpoints require a
  #     valid JWT. This prevents config-overwrite and SSRF attacks after
  #     the initial installation.
  #   - POST /onboarding/setup is a one-time operation: if setup is already
  #     complete and the caller has no valid JWT it is rejected with 409.
  #   - POST /onboarding/health-check: once setup is complete the `base_url`
  #     and `api_key` passthrough params are ignored; the endpoint tests only
  #     the CONFIGURED provider, eliminating the SSRF proxy surface.
  #   - GET /onboarding/models: once setup is complete arbitrary `api_key`
  #     and `base_url` query params are stripped; only configured values are
  #     used.

  get "/onboarding/status" do
    alias OptimalSystemAgent.Onboarding

    # Hotfix: the onboarding picker must ALWAYS get a usable payload. Each
    # risky sub-call (system probing, env/network detection) is isolated so
    # one failing piece degrades to a safe default instead of taking the
    # whole response down with a 500 — a dead /onboarding/status is a hard
    # dead-end for a newcomer (the picker never opens at all, with nothing
    # to retry against).
    needs_onboarding = safe_call(fn -> Onboarding.first_run?() end, true)

    bootstrap_exists =
      safe_call(fn -> File.exists?(Path.expand("~/.osa/BOOTSTRAP.md")) end, false)

    system_info = safe_call(fn -> Onboarding.detect_system() end, %{})
    # providers_list/0 is static data (no I/O), but still isolated: a future
    # change to it must never be able to blank the whole picker.
    providers = safe_call(fn -> Onboarding.providers_list() end, [])

    detected =
      safe_call(fn -> Onboarding.detect_existing() end, %{
        detected: [],
        ollama_local: %{reachable: false, url: "http://localhost:11434", model_count: 0}
      })

    body =
      Jason.encode!(%{
        needs_onboarding: needs_onboarding,
        needs_bootstrap: bootstrap_exists,
        system_info: system_info,
        providers: providers,
        detected: detected
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

    # Once setup is complete, strip caller-supplied credentials to prevent
    # unauthenticated SSRF/key-probing. Authenticated callers may still pass
    # them through.
    {base_url, api_key} =
      if setup_completed?() do
        case verify_bearer(conn) do
          {:ok, _claims} ->
            {conn.query_params["base_url"], conn.query_params["api_key"]}

          {:error, _} ->
            # Setup done, no valid JWT → reject credential params outright.
            conn =
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                401,
                Jason.encode!(%{
                  error: "unauthorized",
                  message: "Authentication required after initial setup."
                })
              )

            Plug.Conn.halt(conn)
            # Unreachable but satisfies the compiler for the tuple match
            {nil, nil}
        end
      else
        {conn.query_params["base_url"], conn.query_params["api_key"]}
      end

    unless conn.halted do
      case OptimalSystemAgent.Onboarding.model_list(provider,
             base_url: base_url,
             api_key: api_key
           ) do
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
  end

  post "/onboarding/health-check" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, params} ->
            # Security: once setup is complete, require auth and ignore
            # caller-supplied base_url / api_key to close the SSRF proxy.
            params =
              if setup_completed?() do
                case verify_bearer(conn) do
                  {:ok, _claims} ->
                    # Authenticated callers (e.g. the in-UI provider/key picker)
                    # may verify a CANDIDATE key for a provider other than the
                    # active one, so we honour caller-supplied api_key/base_url.
                    # Still restricted to the known provider allowlist below,
                    # which bounds the SSRF surface to real LLM endpoints.
                    provider = Map.get(params, "provider", "")

                    if provider not in allowed_health_check_providers() do
                      :reject
                    else
                      params
                    end

                  {:error, _} ->
                    :unauthorized
                end
              else
                # First-run: permit params, but only for known providers.
                provider = Map.get(params, "provider", "")

                if provider not in allowed_health_check_providers() do
                  :reject
                else
                  params
                end
              end

            case params do
              :unauthorized ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(
                  401,
                  Jason.encode!(%{
                    error: "unauthorized",
                    message: "Authentication required after initial setup."
                  })
                )

              :reject ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(
                  400,
                  Jason.encode!(%{
                    error: "invalid_provider",
                    message: "Provider not recognised. Use a supported provider name."
                  })
                )

              safe_params ->
                case OptimalSystemAgent.Onboarding.health_check(safe_params) do
                  {:ok, result} ->
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(200, Jason.encode!(result))

                  {:error, result} ->
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(200, Jason.encode!(result))
                end
            end

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, ~s({"error":"invalid_json"}))
        end

      {:more, _partial, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, ~s({"error":"payload_too_large"}))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"error":"read_failed"}))
    end
  end

  # ── Anthropic sign-in: REMOVED ───────────────────────────────────────
  #
  # These four routes used to drive an OAuth 2.0 + PKCE flow against
  # console.anthropic.com with Claude Code's first-party client id. The flow is
  # gone (see `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`): it made the USER
  # breach Anthropic's Consumer Terms, Anthropic blocks it server-side, and the
  # token endpoint now 404s.
  #
  # The routes are kept as explicit `410 Gone` responses rather than deleted so
  # an older desktop/TUI build that still calls them gets a clear, actionable
  # message instead of a 404 from the catch-all, or a silent no-op. Anthropic
  # API-key setup is unaffected — use `POST /onboarding/setup`.

  get "/onboarding/oauth/start" do
    send_oauth_gone(conn)
  end

  get "/onboarding/oauth/callback" do
    send_oauth_gone_html(conn)
  end

  get "/onboarding/oauth/status" do
    send_oauth_gone(conn)
  end

  delete "/onboarding/oauth/status" do
    send_oauth_gone(conn)
  end

  post "/onboarding/setup" do
    # One-time operation: if setup is already complete, require a valid JWT.
    # This prevents any unauthenticated caller from overwriting the existing
    # provider config (including API keys) after the first successful setup.
    auth_result =
      if setup_completed?() do
        case verify_bearer(conn) do
          {:ok, claims} -> {:ok, claims}
          {:error, _} -> :setup_locked
        end
      else
        :first_run
      end

    case auth_result do
      :setup_locked ->
        Logger.warning(
          "[Onboarding] POST /onboarding/setup blocked: setup already complete and no valid JWT presented (remote_ip=#{inspect(conn.remote_ip)})"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          409,
          Jason.encode!(%{
            error: "setup_already_complete",
            message:
              "Initial setup has already been completed. Re-configure via the authenticated API (/api/v1/settings)."
          })
        )

      _ ->
        # :first_run or {:ok, claims} — proceed with write_setup
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
                          {:ok, desc} ->
                            %{status: "ok", check: desc}

                          {:error, desc, reason} ->
                            %{status: "error", check: desc, reason: reason}
                        end)
                      rescue
                        _ -> []
                      end

                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(
                      200,
                      Jason.encode!(%{
                        status: "ok",
                        provider: Map.get(params, "provider"),
                        model: Map.get(params, "model"),
                        checks: checks
                      })
                    )

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
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(413, ~s({"error":"payload_too_large"}))

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, ~s({"error":"read_failed"}))
        end
    end
  end

  # ── Survey / waitlist (no auth — anonymous submissions) ─────────────

  post "/api/survey" do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, body} ->
            :ets.insert(
              :osa_survey_responses,
              {System.unique_integer([:positive]), body, DateTime.utc_now()}
            )

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

            :ets.insert(
              :osa_survey_responses,
              {System.unique_integer([:positive]), attrs, DateTime.utc_now()}
            )

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

  # ── Onboarding security helpers ─────────────────────────────────────

  # Returns true when at least one provider has been configured (i.e. ~/.osa/.env
  # exists with a valid OSA_DEFAULT_PROVIDER entry). The inverse of first_run?/0.
  defp setup_completed? do
    not OptimalSystemAgent.Onboarding.first_run?()
  end

  # Extract and verify the Bearer JWT from the Authorization header.
  # Returns {:ok, claims} or {:error, reason}.
  defp verify_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        OptimalSystemAgent.Channels.HTTP.Auth.verify_token(token)

      _ ->
        {:error, :missing_token}
    end
  end

  # Provider slugs that may be passed to POST /onboarding/health-check. Any
  # slug not on this list is rejected, so a caller cannot probe arbitrary URLs
  # through the server.
  #
  # DERIVED from the onboarding catalog rather than hand-listed. The hand-listed
  # version had drifted in both directions and each direction was its own bug:
  #
  #   * it admitted `gemini`, `azure` and `bedrock` — slugs the Registry does
  #     not route and `build_health_check_request/4` has no branch for, so they
  #     could only ever answer "no endpoint";
  #   * it OMITTED most providers that ARE routable (cerebras, fireworks,
  #     together, perplexity, replicate, the Chinese providers, the local
  #     servers), so a user who picked one got a 400 `invalid_provider` from
  #     their own machine instead of a key check.
  #
  # Deriving it means the allowlist can never be narrower than the picker (a
  # provider you can select but not verify) nor wider than the routing table
  # (a slug with no honest endpoint).
  @extra_health_check_slugs ~w(ollama)

  defp allowed_health_check_providers do
    ids =
      OptimalSystemAgent.Onboarding.providers_list()
      |> Enum.map(& &1.id)

    ids ++ @extra_health_check_slugs
  rescue
    # Never let a catalog problem turn every key check into a 400.
    _ -> ~w(anthropic openai ollama ollama_local ollama_cloud openrouter miosa custom)
  end

  # Run a risky call, degrading to `default` on ANY exception/throw/exit
  # instead of letting it crash the whole response (onboarding hotfix: a
  # 500 from /onboarding/status is a hard dead-end for a newcomer since the
  # picker never opens). Logs so the degraded path is still visible in
  # operator logs even though the caller gets a 200.
  defp safe_call(fun, default) do
    fun.()
  catch
    kind, reason ->
      Logger.warning(
        "[Onboarding] status sub-call failed (#{kind}: #{inspect(reason)}) — using default"
      )

      default
  end

  # Provider atom for the /health context-window lookup. Only ever returns an
  # atom the Registry already knows (never String.to_atom on request-adjacent
  # data), and nil when it can't — nil simply means "no local num_ctx capping".
  defp provider_atom_for_health(provider) when is_binary(provider) do
    Enum.find(
      OptimalSystemAgent.Providers.Registry.list_providers(),
      &(Atom.to_string(&1) == provider)
    )
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp provider_atom_for_health(_), do: nil

  # ── Health billing snapshot ─────────────────────────────────────────
  # Projects the Budget GenServer status into the /health `billing` object.
  # `subscription` is intentionally nil: OSA tracks only local USD spend and
  # has no subscription/plan concept. Returns nil if Budget is unavailable so
  # the field degrades gracefully rather than raising.
  defp health_billing(provider, model) do
    case OptimalSystemAgent.Budget.get_status() do
      {:ok, status} when is_map(status) -> billing_from_status(status, provider, model)
      status when is_map(status) -> billing_from_status(status, provider, model)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp billing_from_status(status, provider, model) do
    %{
      daily_spent_usd: Map.get(status, :daily_spent, 0.0),
      daily_limit_usd: Map.get(status, :daily_limit),
      monthly_spent_usd: Map.get(status, :monthly_spent, 0.0),
      monthly_limit_usd: Map.get(status, :monthly_limit),
      # Tokens used today — meaningful even when USD spend is $0 (providers
      # without per-token pricing, e.g. GLM/Ollama). The TUI shows this when
      # `usd_pricing` is false, instead of a meaningless "$0/$50 today".
      daily_tokens: Map.get(status, :daily_tokens, 0),
      # True only when the active provider/model has real USD cost data so
      # spend can actually be nonzero. False → the status line should surface
      # token usage rather than dollars.
      usd_pricing: active_usd_pricing?(provider, model),
      currency: "USD",
      subscription: nil
    }
  end

  # True when the active provider has explicit non-zero per-token USD rates, or
  # the active model carries real (non-zero) pricing in the models.dev catalog.
  # False for pricing-less providers (GLM/zhipu, Ollama) so spend is known to be
  # $0 and the TUI can show tokens instead.
  defp active_usd_pricing?(provider, model) do
    OptimalSystemAgent.Budget.has_usd_pricing?(provider) or catalog_model_priced?(model)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp catalog_model_priced?(model) when is_binary(model) do
    case OptimalSystemAgent.Providers.Catalog.cost(model) do
      %{input: input, output: output}
      when (is_number(input) and input > 0) or (is_number(output) and output > 0) ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp catalog_model_priced?(_), do: false

  defp send_oauth_gone(conn) do
    body =
      Jason.encode!(%{
        error: "anthropic_oauth_removed",
        message: OptimalSystemAgent.Auth.LegacyAnthropicOAuth.notice(),
        connected: false
      })

    conn |> put_resp_content_type("application/json") |> send_resp(410, body)
  end

  defp send_oauth_gone_html(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(410, """
    <html><body style="background:#0a0a0a;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
    <div style="text-align:center;max-width:34rem;padding:0 1.5rem"><h2 style="color:#f87171">Anthropic sign-in is no longer available</h2><p style="color:#888">#{Plug.HTML.html_escape(OptimalSystemAgent.Auth.LegacyAnthropicOAuth.notice())}</p></div>
    </body></html>
    """)
  end
end
