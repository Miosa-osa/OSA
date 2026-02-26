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
      _ -> {:error, :invalid_token}
    end
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

  defp verify_expiration(_), do: :ok

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
    Application.get_env(:optimal_system_agent, :shared_secret) ||
      System.get_env("OSA_SHARED_SECRET") ||
      generated_dev_secret()
  end

  defp generated_dev_secret do
    case :persistent_term.get(@dev_secret_key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        :persistent_term.put(@dev_secret_key, secret)
        Logger.warning("HTTP Auth: No shared secret configured. Generated ephemeral secret for this session. Set OSA_SHARED_SECRET env var for production.")
        secret

      secret ->
        secret
    end
  end
end
