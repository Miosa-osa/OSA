defmodule OptimalSystemAgent.Agent.DurableInbox do
  @moduledoc """
  Durable FIFO lanes for facts that must cross a running-turn or restart seam.

  ETS remains the low-latency live projection. The session sidecar is the
  durable ledger. Consumers reserve entries in ETS, persist their incorporation,
  then acknowledge the exact durable records. A crash before acknowledgement
  therefore leaves the entries available to the replacement process.
  """

  require Logger

  alias OptimalSystemAgent.Agent.SessionPersistence

  @type lane :: :steers | :task_notifications
  @append_attempts 4
  @retry_ms 10

  @spec append(atom(), String.t(), lane(), map()) :: :ok | {:error, term()}
  def append(table, session_id, lane, payload)
      when is_atom(table) and is_binary(session_id) and is_map(payload) do
    entry = %{
      "id" => unique_id(),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => stringify(payload)
    }

    case append_durable(session_id, lane, entry, @append_attempts) do
      :ok ->
        seq = :erlang.unique_integer([:monotonic, :positive])
        true = :ets.insert(table, {{session_id, seq}, entry})
        :ok

      {:error, reason} ->
        Logger.error(
          "[durable_inbox] append failed for #{session_id}/#{lane}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp append_durable(session_id, lane, entry, attempts) do
    case SessionPersistence.append_inbox(session_id, lane, entry) do
      {:error, :contended} when attempts > 1 ->
        Process.sleep(@retry_ms)
        append_durable(session_id, lane, entry, attempts - 1)

      outcome ->
        outcome
    end
  end

  @spec restore(atom(), String.t(), lane()) :: :ok
  def restore(table, session_id, lane) do
    if live_entries(table, session_id) == [] do
      SessionPersistence.load_inbox(session_id, lane)
      |> Enum.each(fn entry ->
        seq = :erlang.unique_integer([:monotonic, :positive])
        :ets.insert(table, {{session_id, seq}, entry})
      end)
    end

    :ok
  end

  @spec drain(atom(), String.t(), lane()) :: [map()]
  def drain(table, session_id, lane) do
    case checkout(table, session_id, lane) do
      :empty ->
        []

      {receipt, payloads} ->
        :ok = acknowledge(table, session_id, lane, receipt)
        payloads
    end
  end

  @doc "Reserve current entries without deleting their durable records."
  @spec checkout(atom(), String.t(), lane()) :: :empty | {[String.t()], [map()]}
  def checkout(table, session_id, lane) do
    restore(table, session_id, lane)

    candidates =
      table
      |> live_entries(session_id)
      |> Enum.reject(fn {_seq, entry} -> entry["claimed"] == true end)

    rows =
      Enum.filter(candidates, fn {seq, entry} ->
        claimed = Map.put(entry, "claimed", true)

        :ets.select_replace(table, [
          {
            {{session_id, seq}, :"$1"},
            [{:==, :"$1", {:const, entry}}],
            [{:const, {{session_id, seq}, claimed}}]
          }
        ]) == 1
      end)

    case rows do
      [] ->
        :empty

      _ ->
        ids = Enum.map(rows, fn {_seq, entry} -> entry["id"] end)

        payloads =
          Enum.map(rows, fn {_seq, entry} -> atomize_payload(entry["payload"] || %{}) end)

        {ids, payloads}
    end
  end

  @doc "Acknowledge reserved entries after the consumer has persisted incorporation."
  @spec acknowledge(atom(), String.t(), lane(), [String.t()]) :: :ok | {:error, term()}
  def acknowledge(table, session_id, lane, ids) do
    case SessionPersistence.acknowledge_inbox(session_id, lane, ids) do
      :ok ->
        ids = MapSet.new(ids)

        live_entries(table, session_id)
        |> Enum.each(fn {seq, entry} ->
          if MapSet.member?(ids, entry["id"]), do: :ets.delete(table, {session_id, seq})
        end)

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Release a live reservation after incorporation could not be persisted."
  @spec release(atom(), String.t(), [String.t()]) :: :ok
  def release(table, session_id, ids) do
    ids = MapSet.new(ids)

    live_entries(table, session_id)
    |> Enum.each(fn {seq, entry} ->
      if MapSet.member?(ids, entry["id"]) do
        :ets.insert(table, {{session_id, seq}, Map.delete(entry, "claimed")})
      end
    end)

    :ok
  end

  @spec count(atom(), String.t(), lane()) :: non_neg_integer()
  def count(table, session_id, lane) do
    restore(table, session_id, lane)
    length(live_entries(table, session_id))
  end

  defp live_entries(table, session_id) do
    match = [{{{session_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
    table |> :ets.select(match) |> Enum.sort_by(&elem(&1, 0))
  end

  defp unique_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp atomize_payload(map) do
    Map.new(map, fn {key, value} -> {safe_key(key), value} end)
  end

  defp safe_key(key) when is_atom(key), do: key

  defp safe_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
