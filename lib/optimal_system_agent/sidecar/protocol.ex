defmodule OptimalSystemAgent.Sidecar.Protocol do
  @moduledoc """
  Shared JSON-RPC protocol for sidecar processes (Go tokenizer, Python embeddings).

  Both sidecars communicate over newline-delimited JSON-RPC via stdio:

      Request:  {"id":"abc","method":"count_tokens","params":{"text":"hello"}}\n
      Response: {"id":"abc","result":{"count":3}}\n
      Error:    {"id":"abc","error":{"code":-1,"message":"failed"}}\n

  Each message is a single JSON line terminated by `\\n`.
  The `id` field correlates requests with responses.
  """

  @doc """
  Encode a JSON-RPC request as a newline-terminated binary.

  Returns `{id, encoded_line}` where `id` is the generated correlation ID.
  """
  @spec encode_request(String.t(), map()) :: {String.t(), binary()}
  def encode_request(method, params \\ %{}) do
    id = generate_id()

    payload = %{
      "id" => id,
      "method" => method,
      "params" => params
    }

    {id, Jason.encode!(payload) <> "\n"}
  end

  @doc """
  Decode a JSON-RPC response line.

  Returns one of:
    - `{:ok, id, result}` — successful response
    - `{:error, id, error_map}` — error response with code + message
    - `{:error, :invalid, reason}` — malformed line
  """
  @spec decode_response(binary()) ::
          {:ok, String.t(), map()} | {:error, String.t(), map()} | {:error, :invalid, String.t()}
  def decode_response(line) do
    line = String.trim(line)

    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} ->
        {:ok, id, result}

      {:ok, %{"id" => id, "error" => error}} ->
        {:error, id, error}

      {:ok, _other} ->
        {:error, :invalid, "missing id/result/error fields"}

      {:error, reason} ->
        {:error, :invalid, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Generate a unique request ID (8-char hex).
  """
  @spec generate_id() :: String.t()
  def generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
