defmodule OptimalSystemAgent.Receipt.Verifier do
  @moduledoc "Verifies Ed25519 signatures from kernel audit responses."

  require Logger

  @doc """
  Verify an Ed25519 signature over an attestation hash.

  All arguments are hex-encoded strings. Returns true if the signature is valid.
  """
  @spec verify(String.t(), String.t(), String.t()) :: boolean()
  def verify(attestation_hex, signature_hex, pubkey_hex) do
    # The kernel signs []byte(attestation_hex), i.e. the UTF-8 bytes of the
    # hex string itself — NOT the decoded hash bytes. We must verify the same.
    with {:ok, sig} <- decode_hex(signature_hex),
         {:ok, pubkey} <- decode_hex(pubkey_hex) do
      :crypto.verify(:eddsa, :none, attestation_hex, sig, [pubkey, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Fetch the kernel's Ed25519 public key from the /api/audit/pubkey endpoint.

  Returns `{:ok, hex_string}` or `{:error, reason}`.
  """
  @spec fetch_pubkey(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_pubkey(kernel_http_url) do
    url = "#{kernel_http_url}/api/audit/pubkey"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"public_key" => key}}} when is_binary(key) ->
        Logger.info("[Receipt.Verifier] Fetched kernel public key: #{String.slice(key, 0, 16)}...")
        {:ok, key}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_hex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_hex}
    end
  end

  defp decode_hex(_), do: {:error, :not_a_string}
end
