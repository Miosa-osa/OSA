defmodule OptimalSystemAgent.Security.Evidence do
  @moduledoc """
  Append-only hashed evidence chain for an engagement.

  An artifact-backed finding is what separates a finding from a rumor. Each record is a SHA-256 of the bytes plus a pointer
  to the previous hash, so a skeptic can re-hash cited artifacts instead of
  trusting prose. No network. No payloads - just custody of whatever the
  operator already captured (HAR, request dump, screenshot, SARIF).
  """

  @table :osa_security_evidence

  @type record :: %{
          id: String.t(),
          finding_key: String.t() | nil,
          kind: String.t(),
          sha256: String.t(),
          prev: String.t() | nil,
          bytes: non_neg_integer(),
          path: String.t() | nil,
          note: String.t(),
          inserted_at: DateTime.t()
        }

  @doc "Record bytes (or a file path) onto the session chain."
  @spec record(String.t(), keyword()) :: {:ok, record()} | {:error, String.t()}
  def record(session_id, opts) when is_binary(session_id) and is_list(opts) do
    ensure_table()

    with {:ok, bin, path} <- read_bytes(opts) do
      sha = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
      prev = last_hash(session_id)

      rec = %{
        id: "ev-" <> binary_part(sha, 0, 12),
        finding_key: Keyword.get(opts, :finding_key),
        kind: to_string(Keyword.get(opts, :kind, "artifact")),
        sha256: sha,
        prev: prev,
        bytes: byte_size(bin),
        path: path,
        note: Keyword.get(opts, :note, ""),
        inserted_at: DateTime.utc_now()
      }

      :ets.insert(@table, {{session_id, rec.id}, rec, System.unique_integer([:monotonic])})
      {:ok, rec}
    end
  end

  @doc "All records for a session, in insertion order."
  @spec list(String.t()) :: [record()]
  def list(session_id) when is_binary(session_id) do
    ensure_table()

    @table
    |> :ets.match({{session_id, :_}, :"$1", :"$2"})
    |> Enum.sort_by(fn [_rec, seq] -> seq end)
    |> Enum.map(fn [rec, _] -> rec end)
  end

  @doc "Verify the chain hashes link. Returns :ok or {:error, broken_id}."
  @spec verify(String.t()) :: :ok | {:error, String.t()}
  def verify(session_id) when is_binary(session_id) do
    case list(session_id) do
      [] ->
        :ok

      recs ->
        recs
        |> Enum.reduce_while(nil, fn rec, prev ->
          if rec.prev == prev, do: {:cont, rec.sha256}, else: {:halt, {:error, rec.id}}
        end)
        |> case do
          {:error, _} = err -> err
          _ -> :ok
        end
    end
  end

  defp read_bytes(opts) do
    cond do
      is_binary(Keyword.get(opts, :bytes)) ->
        {:ok, Keyword.get(opts, :bytes), Keyword.get(opts, :path)}

      is_binary(Keyword.get(opts, :path)) ->
        path = Keyword.get(opts, :path)

        case File.read(path) do
          {:ok, bin} -> {:ok, bin, path}
          {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
        end

      true ->
        {:error, "provide :bytes or :path"}
    end
  end

  defp last_hash(session_id) do
    case list(session_id) do
      [] -> nil
      recs -> List.last(recs).sha256
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :ordered_set])
      _ -> :ok
    end
  end
end
