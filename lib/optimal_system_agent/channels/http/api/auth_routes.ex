defmodule OptimalSystemAgent.Channels.HTTP.API.AuthRoutes do
  @moduledoc """
  Auth routes — POST /login, /logout, /refresh.

  These routes are forwarded to before the JWT authenticate plug runs,
  so no bearer token is required.

  ## Login security

  When `OSA_REQUIRE_AUTH` is true (or `OSA_SHARED_SECRET` is set), the
  login endpoint requires the shared secret in the POST body:

      POST /login
      {"user_id": "alice", "secret": "<OSA_SHARED_SECRET>"}

  If the secret is missing or wrong, a 401 is returned. In dev mode
  (no shared secret configured), open access is preserved but a warning
  is logged on every login so operators notice the gap.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  require Logger

  alias OptimalSystemAgent.Channels.HTTP.Auth

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000
  )

  plug(:dispatch)

  # ── POST /login ────────────────────────────────────────────────────

  post "/login" do
    with :ok <- verify_login_secret(conn) do
      user_id =
        get_in(conn.body_params, ["user_id"]) ||
          default_user_id()

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
    else
      {:error, :unauthorized} ->
        json_error(conn, 401, "unauthorized", "Invalid or missing secret")
    end
  end

  # ── POST /logout ───────────────────────────────────────────────────

  post "/logout" do
    # Stateless JWT — nothing to invalidate server-side
    body = Jason.encode!(%{"ok" => true})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /refresh ──────────────────────────────────────────────────

  post "/refresh" do
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

  match _ do
    json_error(conn, 404, "not_found", "Auth endpoint not found")
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Local OSA is one user talking to one loopback-only daemon. A random id here
  # made that same person become a different session owner after every fresh
  # login, especially after an ephemeral JWT secret rotated on backend restart.
  # Keep remote fallback behaviour isolated; authenticated deployments should
  # continue sending an explicit account id.
  defp default_user_id do
    if Auth.loopback_only?(),
      do: "local",
      else: "tui_#{System.unique_integer([:positive])}"
  end

  # Returns :ok when the request is allowed to proceed, {:error, :unauthorized}
  # when the secret check fails.
  #
  # Logic:
  #   1. If require_auth is true OR a shared_secret is configured → enforce secret.
  #   2. Otherwise (dev mode) → warn and allow.
  defp verify_login_secret(conn) do
    require_auth = Application.get_env(:optimal_system_agent, :require_auth, false)
    configured_secret = Application.get_env(:optimal_system_agent, :shared_secret)

    if require_auth or not is_nil(configured_secret) do
      provided = get_in(conn.body_params, ["secret"]) || ""

      if configured_secret && Plug.Crypto.secure_compare(configured_secret, provided) do
        :ok
      else
        Logger.warning(
          "[AuthRoutes] Login rejected — secret mismatch from #{format_remote_ip(conn)}"
        )

        {:error, :unauthorized}
      end
    else
      # No auth configured — only allow open-access on loopback bindings.
      # On non-loopback (0.0.0.0, a LAN/WAN address, etc.) reject the
      # request so that any process on the network cannot obtain a valid JWT
      # without providing credentials.
      if Auth.loopback_only?() do
        Logger.warning(
          "[AuthRoutes] Login without secret verification (loopback-only mode) — " <>
            "set OSA_SHARED_SECRET or OSA_REQUIRE_AUTH=true to enable auth"
        )

        :ok
      else
        Logger.error(
          "[AuthRoutes] Login rejected — server is bound to a non-loopback address " <>
            "but no OSA_SHARED_SECRET / OSA_REQUIRE_AUTH is configured. " <>
            "Set OSA_SHARED_SECRET to enable authenticated logins."
        )

        {:error, :unauthorized}
      end
    end
  end

  defp format_remote_ip(%{remote_ip: {a, b, c, d}}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_remote_ip(%{remote_ip: ip}), do: inspect(ip)
end
