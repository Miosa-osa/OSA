defmodule OptimalSystemAgent.MCP.Protocol.JSONRPC do
  @moduledoc """
  Pure JSON-RPC 2.0 encoding/decoding for MCP.

  No I/O and no process state — every function is a pure transformation on
  maps and binaries. Request ids are drawn from a monotonic counter so that
  concurrent callers never collide within a running node.

  See https://www.jsonrpc.org/specification and the MCP transport spec.
  """

  @version "2.0"

  @doc "Return a fresh, process-global, monotonically increasing request id."
  @spec next_id() :: pos_integer()
  def next_id do
    System.unique_integer([:positive, :monotonic])
  end

  @doc """
  Build a JSON-RPC request map with an id (expects a response).

  `id` defaults to a fresh monotonic id. Returns the decoded map — encode it
  with `encode/1` before writing to a transport.
  """
  @spec request(String.t(), map() | nil, integer() | nil) :: map()
  def request(method, params \\ nil, id \\ nil) do
    id = id || next_id()

    %{"jsonrpc" => @version, "id" => id, "method" => method}
    |> put_params(params)
  end

  @doc "Build a JSON-RPC notification map (no id, no response expected)."
  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) do
    %{"jsonrpc" => @version, "method" => method}
    |> put_params(params)
  end

  @doc "Build a successful JSON-RPC response for the given id."
  @spec response(integer() | String.t(), term()) :: map()
  def response(id, result) do
    %{"jsonrpc" => @version, "id" => id, "result" => result}
  end

  @doc "Build a JSON-RPC error response for the given id."
  @spec error_response(integer() | String.t() | nil, integer(), String.t(), term()) :: map()
  def error_response(id, code, message, data \\ nil) do
    error =
      %{"code" => code, "message" => message}
      |> maybe_put("data", data)

    %{"jsonrpc" => @version, "id" => id, "error" => error}
  end

  @doc "Encode a message map to a JSON binary."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(message) when is_map(message) do
    Jason.encode(message)
  end

  @doc "Encode a message map to a JSON binary, raising on failure."
  @spec encode!(map()) :: binary()
  def encode!(message) when is_map(message), do: Jason.encode!(message)

  @doc """
  Decode a JSON binary into a classified JSON-RPC message.

  Returns one of:
    * `{:ok, {:response, id, result}}`
    * `{:ok, {:error, id, %{code, message, data}}}`
    * `{:ok, {:request, id, method, params}}`
    * `{:ok, {:notification, method, params}}`
    * `{:error, reason}` on malformed JSON or a non-conforming envelope
  """
  @spec decode(binary()) ::
          {:ok,
           {:response, term(), term()}
           | {:error, term(), map()}
           | {:request, term(), String.t(), map()}
           | {:notification, String.t(), map()}}
          | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} when is_map(map) -> classify(map)
      {:ok, _other} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc "Classify an already-decoded JSON-RPC map. See `decode/1`."
  @spec classify(map()) :: {:ok, tuple()} | {:error, term()}
  def classify(%{"error" => %{} = err} = map) do
    {:ok, {:error, Map.get(map, "id"), normalize_error(err)}}
  end

  def classify(%{"result" => result, "id" => id}) do
    {:ok, {:response, id, result}}
  end

  def classify(%{"method" => method} = map) do
    if Map.has_key?(map, "id") do
      {:ok, {:request, map["id"], method, Map.get(map, "params", %{})}}
    else
      {:ok, {:notification, method, Map.get(map, "params", %{})}}
    end
  end

  def classify(_), do: {:error, :unrecognized_envelope}

  # ── Private ───────────────────────────────────────────────────────────

  defp normalize_error(%{} = err) do
    %{
      code: Map.get(err, "code"),
      message: Map.get(err, "message"),
      data: Map.get(err, "data")
    }
  end

  defp put_params(map, nil), do: map
  defp put_params(map, params) when is_map(params), do: Map.put(map, "params", params)
  defp put_params(map, _), do: map

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
