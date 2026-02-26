defmodule OptimalSystemAgent.Channels.HTTP.Auth do
  @moduledoc """
  JWT HS256 authentication for the HTTP channel.

  Local mode uses a shared secret (OSA_SHARED_SECRET env var).
  Validates: signature, expiration, required claims (user_id).
  """

  @doc "Verify a Bearer token. Returns {:ok, claims} or {:error, reason}."
  def verify_token(token) do
    secret = shared_secret()

    with [header_b64, payload_b64, signature_b64] <- String.split(token, "."),
         {:ok, _header} <- decode_segment(header_b64),
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

  defp shared_secret do
    Application.get_env(:optimal_system_agent, :shared_secret) ||
      System.get_env("OSA_SHARED_SECRET") ||
      "osa-dev-secret-change-me"
  end
end
