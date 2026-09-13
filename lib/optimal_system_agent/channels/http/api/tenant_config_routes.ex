defmodule OptimalSystemAgent.Channels.HTTP.API.TenantConfigRoutes do
  @moduledoc """
  Tenant configuration API routes.

  Forwarded prefix: /tenant-config

  Routes:
    GET  /          -> full tenant config
    PUT  /          -> update full config
    GET  /llm       -> LLM provider configs
    PUT  /llm       -> update LLM providers
    GET  /compute   -> compute config
    PUT  /compute   -> update compute
    GET  /limits    -> resource limits
    PUT  /limits    -> update limits
    POST /llm/test  -> test an LLM provider key
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Tenant.Config

  @compile {:no_warn_undefined, [OptimalSystemAgent.Tenant.Config]}

  plug(:match)
  plug(:dispatch)

  # ── Helpers ────────────────────────────────────────────────────────

  defp tenant_id(conn) do
    conn.assigns[:workspace_id] || conn.assigns[:user_id] || "default"
  end

  defp json_ok(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data))
  end

  # ── GET / — full tenant config ────────────────────────────────────

  get "/" do
    config = Config.get(tenant_id(conn))
    json_ok(conn, %{config: config})
  end

  # ── PUT / — update full config ────────────────────────────────────

  put "/" do
    case conn.body_params do
      %{"config" => config} when is_map(config) ->
        Config.put(tenant_id(conn), config)
        json_ok(conn, %{status: "updated", config: Config.get(tenant_id(conn))})

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: config")
    end
  end

  # ── GET /llm — LLM provider configs ──────────────────────────────

  get "/llm" do
    providers = Config.get_llm_providers(tenant_id(conn))
    json_ok(conn, %{llm_providers: providers})
  end

  # ── PUT /llm — update LLM providers ──────────────────────────────

  put "/llm" do
    case conn.body_params do
      %{"llm_providers" => providers} when is_list(providers) ->
        Config.set_llm_providers(tenant_id(conn), providers)

        json_ok(conn, %{
          status: "updated",
          llm_providers: Config.get_llm_providers(tenant_id(conn))
        })

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: llm_providers (array)")
    end
  end

  # ── GET /compute — compute config ─────────────────────────────────

  get "/compute" do
    compute = Config.get_compute(tenant_id(conn))
    json_ok(conn, %{compute: compute})
  end

  # ── PUT /compute — update compute config ──────────────────────────

  put "/compute" do
    case conn.body_params do
      %{"compute" => compute} when is_map(compute) ->
        Config.set_compute(tenant_id(conn), compute)
        json_ok(conn, %{status: "updated", compute: Config.get_compute(tenant_id(conn))})

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: compute")
    end
  end

  # ── GET /limits — resource limits ─────────────────────────────────

  get "/limits" do
    limits = Config.get_limits(tenant_id(conn))
    json_ok(conn, %{limits: limits})
  end

  # ── PUT /limits — update limits ───────────────────────────────────

  put "/limits" do
    case conn.body_params do
      %{"limits" => limits} when is_map(limits) ->
        Config.set_limits(tenant_id(conn), limits)
        json_ok(conn, %{status: "updated", limits: Config.get_limits(tenant_id(conn))})

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: limits")
    end
  end

  # ── POST /llm/test — test an LLM provider key ────────────────────

  post "/llm/test" do
    case conn.body_params do
      %{"provider" => provider, "api_key" => api_key}
      when is_binary(provider) and is_binary(api_key) ->
        # Placeholder — always returns valid for now
        json_ok(conn, %{provider: provider, status: "valid", message: "Key accepted"})

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required fields: provider, api_key")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Tenant config endpoint not found")
  end
end
