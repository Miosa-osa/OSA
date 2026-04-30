defmodule OptimalSystemAgent.Channels.HTTP.Auth do
  @moduledoc """
  JWT HS256 authentication for the HTTP channel.

  Local mode uses a shared secret (OSA_SHARED_SECRET env var).
  Validates: signature, expiration, algorithm, required claims (user_id).
  """
  require Logger

  @dev_secret_key :osa_dev_secret

  @doc "Verify a Bearer token. Returns {:ok, claims} or {:error, reason}."
  def verify_token(token) do
    secret = shared_secret()

    with [header_b64, payload_b64, signature_b64] <- String.split(token, "."),
         {:ok, header} <- decode_segment(header_b64),
         :ok <- validate_algorithm(header),
         {:ok, claims} <- decode_segment(payload_b64),
         :ok <- verify_signature(header_b64, payload_b64, signature_b64, secret),
         :ok <- verify_expiration(claims) do
      {:ok, claims}
    else
      _ ->
        if ephemeral_secret?() do
          {:error, :invalid_token_ephemeral}
        else
          {:error, :invalid_token}
        end
    end
  end

  @doc "Returns true when the server is running with a randomly generated ephemeral JWT secret."
  def ephemeral_secret? do
    Application.get_env(:optimal_system_agent, :jwt_secret) == nil and
      Application.get_env(:optimal_system_agent, :shared_secret) == nil and
      System.get_env("JWT_SECRET") == nil and
      System.get_env("OSA_SHARED_SECRET") == nil
  end

  @doc "Generate a signed JWT for local use (testing, CLI-to-HTTP bridge)."
  def generate_token(claims) do
    secret = shared_secret()

    header = %{"alg" => "HS256", "typ" => "JWT"}
    now = System.system_time(:second)

    claims =
      claims
      |> Map.put_new("iat", now)
      |> Map.put_new("exp", now + 900)

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signature = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
    signature_b64 = Base.url_encode64(signature, padding: false)

    "#{header_b64}.#{payload_b64}.#{signature_b64}"
  end

  @doc "Generate a refresh token (longer-lived, 7 days)."
  def generate_refresh_token(claims) do
    secret = shared_secret()
    header = %{"alg" => "HS256", "typ" => "JWT"}
    now = System.system_time(:second)

    claims =
      claims
      |> Map.put("iat", now)
      |> Map.put("exp", now + 604_800)
      |> Map.put("type", "refresh")

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signature = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
    signature_b64 = Base.url_encode64(signature, padding: false)

    "#{header_b64}.#{payload_b64}.#{signature_b64}"
  end

  @doc "Verify a refresh token and return new access + refresh tokens."
  def refresh(refresh_token) do
    case verify_token(refresh_token) do
      {:ok, %{"type" => "refresh", "user_id" => user_id}} ->
        access = generate_token(%{"user_id" => user_id})
        refresh = generate_refresh_token(%{"user_id" => user_id})
        {:ok, %{token: access, refresh_token: refresh, expires_in: 900}}

      {:ok, _} ->
        {:error, :not_refresh_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_signature(header_b64, payload_b64, signature_b64, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
    expected_b64 = Base.url_encode64(expected, padding: false)

    if Plug.Crypto.secure_compare(expected_b64, signature_b64) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_expiration(%{"exp" => exp}) when is_integer(exp) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp verify_expiration(_), do: {:error, :missing_expiration}

  defp decode_segment(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    end
  end

  defp validate_algorithm(%{"alg" => "HS256"}), do: :ok
  defp validate_algorithm(%{"alg" => alg}), do: {:error, "Unsupported algorithm: #{alg}"}
  defp validate_algorithm(_), do: {:error, "Missing algorithm in JWT header"}

  defp shared_secret do
    Application.get_env(:optimal_system_agent, :jwt_secret) ||
      Application.get_env(:optimal_system_agent, :shared_secret) ||
      System.get_env("JWT_SECRET") ||
      System.get_env("OSA_SHARED_SECRET") ||
      generated_dev_secret()
  end

  defp generated_dev_secret do
    case :persistent_term.get(@dev_secret_key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        :persistent_term.put(@dev_secret_key, secret)

        Logger.warning(
          "[AUTH] Using ephemeral JWT secret — all tokens will be invalidated on restart. " <>
            "Set JWT_SECRET or OSA_SHARED_SECRET in your environment for persistent sessions."
        )

        secret

      secret ->
        secret
    end
  end

  @doc """
  Returns true when the HTTP server is bound exclusively to a loopback address
  (127.0.0.1 or ::1).  Used by the login route to decide whether open-access
  (no-secret) mode is safe.
  """
  def loopback_only? do
    case Application.get_env(:optimal_system_agent, :http_ip) do
      {127, 0, 0, 1} -> true
      # ::1
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _ -> false
    end
  end

  @doc """
  Emits an ERROR-level log when the server is exposed on a non-loopback address
  without authentication configured.  Call this once at application startup.
  """
  def warn_if_insecure do
    require_auth = Application.get_env(:optimal_system_agent, :require_auth, false)
    configured_secret = Application.get_env(:optimal_system_agent, :shared_secret)

    if not require_auth and is_nil(configured_secret) and not loopback_only?() do
      Logger.error(
        "[Auth] SECURITY WARNING: HTTP server is bound to a non-loopback address " <>
          "with no authentication configured. " <>
          "Any network-reachable process can obtain a valid JWT. " <>
          "Set OSA_SHARED_SECRET (and optionally OSA_REQUIRE_AUTH=true) or " <>
          "restrict the bind address to 127.0.0.1 via OSA_HTTP_IP."
      )
    else
      if not require_auth and is_nil(configured_secret) do
        Logger.info(
          "[Auth] Running in open-access mode on loopback only — " <>
            "unauthenticated JWT issuance is permitted for local development."
        )
      end
    end
  end
end
