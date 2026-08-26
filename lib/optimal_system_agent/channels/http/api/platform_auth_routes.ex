defmodule OptimalSystemAgent.Channels.HTTP.API.PlatformAuthRoutes do
  @moduledoc """
  Platform auth routes — POST /register, /login, /refresh, /logout, GET /me.

  Mounted at /platform/auth. Registration and login require no token.
  Logout and /me check conn.assigns[:claims] set by upstream JWT plug.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  import Plug.Conn
  require Logger

  alias OptimalSystemAgent.Platform.Auth, as: PlatformAuth
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @compile {:no_warn_undefined, [OptimalSystemAgent.Platform.Auth]}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000
  )

  plug(:dispatch)

  # ── Platform-enabled guard ───────────────────────────────────────────

  defp platform_enabled?, do: Application.get_env(:optimal_system_agent, :platform_enabled, false)

  defp platform_unavailable(conn) do
    json_error(conn, 503, "platform_unavailable", "Platform database not configured")
  end

  # ── POST /register ─────────────────────────────────────────────────

  post "/register" do
    if platform_enabled?() do
      with %{"email" => email, "password" => password}
           when is_binary(email) and is_binary(password) <- conn.body_params,
           :ok <- validate_email(email),
           :ok <- validate_password(password),
           {:ok, result} <- PlatformAuth.register(conn.body_params) do
        body =
          Jason.encode!(%{
            user: sanitize_user(result.user),
            token: result.token,
            refresh_token: result.refresh_token
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, body)
      else
        {:error, :invalid_email} ->
          json_error(conn, 422, "validation_failed", %{email: ["is not a valid email address"]})

        {:error, :password_too_short} ->
          json_error(conn, 422, "validation_failed", %{
            password: ["must be at least 8 characters"]
          })

        {:error, %Ecto.Changeset{} = cs} ->
          json_error(conn, 422, "validation_failed", changeset_errors(cs))

        {:error, reason} ->
          body = Jason.encode!(%{error: to_string(reason)})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, body)

        _ ->
          json_error(conn, 400, "invalid_request", "email and password must be strings")
      end
    else
      platform_unavailable(conn)
    end
  end

  # ── POST /login ────────────────────────────────────────────────────

  post "/login" do
    if platform_enabled?() do
      with %{"email" => email, "password" => password}
           when is_binary(email) and is_binary(password) <- conn.body_params,
           :ok <- validate_email(email),
           {:ok, result} <- PlatformAuth.login(conn.body_params) do
        body =
          Jason.encode!(%{
            user: sanitize_user(result.user),
            token: result.token,
            refresh_token: result.refresh_token
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      else
        {:error, :invalid_email} ->
          json_error(conn, 422, "validation_failed", %{email: ["is not a valid email address"]})

        {:error, :invalid_credentials} ->
          json_error(conn, 401, "invalid_credentials", "Invalid email or password")

        _ ->
          json_error(conn, 400, "invalid_request", "email and password must be strings")
      end
    else
      platform_unavailable(conn)
    end
  end

  # ── POST /refresh ──────────────────────────────────────────────────

  post "/refresh" do
    if platform_enabled?() do
      case conn.body_params do
        %{"refresh_token" => token} when is_binary(token) and token != "" ->
          case PlatformAuth.refresh(token) do
            {:ok, result} ->
              body = Jason.encode!(result)

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, body)

            _ ->
              json_error(conn, 401, "invalid_refresh_token", "Token is expired or invalid")
          end

        _ ->
          json_error(conn, 422, "invalid_request", "refresh_token must be a non-empty string")
      end
    else
      platform_unavailable(conn)
    end
  end

  # ── POST /logout ───────────────────────────────────────────────────

  post "/logout" do
    if platform_enabled?() do
      conn = maybe_verify_token(conn)

      case conn.assigns[:claims] do
        %{"user_id" => user_id} ->
          PlatformAuth.logout(user_id)

          body = Jason.encode!(%{ok: true})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        _ ->
          json_error(conn, 401, "unauthorized", "Valid token required")
      end
    else
      platform_unavailable(conn)
    end
  end

  # ── GET /me ────────────────────────────────────────────────────────

  get "/me" do
    if platform_enabled?() do
      conn = maybe_verify_token(conn)

      case conn.assigns[:claims] do
        %{"user_id" => user_id} ->
          case PlatformAuth.get_user(user_id) do
            nil ->
              json_error(conn, 404, "user_not_found", "No user found for this token")

            user ->
              body = Jason.encode!(%{user: sanitize_user(user)})

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, body)
          end

        _ ->
          json_error(conn, 401, "unauthorized", "Valid token required")
      end
    else
      platform_unavailable(conn)
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Platform auth endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp sanitize_user(user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      role: user.role,
      avatar_url: user.avatar_url
    }
  end

  defp maybe_verify_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Auth.verify_token(token) do
          {:ok, claims} ->
            conn
            |> assign(:user_id, claims["user_id"])
            |> assign(:claims, claims)

          _ ->
            conn
        end

      _ ->
        conn
    end
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_password(password) do
    if byte_size(password) >= 8, do: :ok, else: {:error, :password_too_short}
  end
end
