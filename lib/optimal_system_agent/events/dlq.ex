defmodule OptimalSystemAgent.Events.DLQ do
  @moduledoc """
  Dead Letter Queue for failed event handler dispatches.

  When an event handler crashes or times out, the event is placed in
  the DLQ for retry with exponential backoff. After `max_retries`
  failures, an algedonic alert is emitted and the event is dropped.

  Backed by ETS for speed — no persistence across restarts (events
  are ephemeral by design; the learning engine captures durable patterns).
  """
  use GenServer
  require Logger

  @table :osa_dlq
  @max_retries 3
  @base_backoff_ms 1_000
  @max_backoff_ms 30_000
  @cleanup_interval_ms 60_000

  defstruct [:id, :event_type, :payload, :handler, :error, :retries, :next_retry_at, :created_at]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Enqueue a failed event for retry."
  @spec enqueue(atom(), map(), function() | {module(), atom(), list()}, term()) :: :ok
  def enqueue(event_type, payload, handler, error) do
    # Store MFA tuples instead of closures — closures can't survive process restarts.
    storable_handler = to_mfa(handler)

    entry = %__MODULE__{
      id: generate_id(),
      event_type: event_type,
      payload: payload,
      handler: storable_handler,
      error: error,
      retries: 0,
      next_retry_at: System.monotonic_time(:millisecond) + @base_backoff_ms,
      created_at: System.monotonic_time(:millisecond)
    }

    :ets.insert(@table, {entry.id, entry})
    Logger.warning("[DLQ] Enqueued failed #{event_type} event: #{inspect(error)}")
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Get current DLQ depth."
  @spec depth() :: non_neg_integer()
  def depth do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @doc "List all entries in the DLQ."
  @spec entries() :: [%__MODULE__{}]
  def entries do
    :ets.tab2list(@table) |> Enum.map(fn {_id, entry} -> entry end)
  rescue
    ArgumentError -> []
  end

  @doc "Manually drain and retry all entries now."
  @spec drain() :: {non_neg_integer(), non_neg_integer()}
  def drain do
    GenServer.call(__MODULE__, :drain)
  end

  # -- GenServer callbacks --

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_retry()
    Logger.info("[DLQ] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    result = process_retries()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:retry_tick, state) do
    process_retries()
    schedule_retry()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internal --

  defp schedule_retry do
    Process.send_after(self(), :retry_tick, @cleanup_interval_ms)
  end

  defp process_retries do
    now = System.monotonic_time(:millisecond)

    entries =
      try do
        :ets.tab2list(@table)
      rescue
        ArgumentError -> []
      end

    ready = Enum.filter(entries, fn {_id, entry} -> entry.next_retry_at <= now end)

    results =
      Enum.map(ready, fn {id, entry} ->
        case retry_handler(entry) do
          :ok ->
            :ets.delete(@table, id)
            :success

          {:error, error} ->
            new_retries = entry.retries + 1

            if new_retries >= @max_retries do
              :ets.delete(@table, id)

              Logger.error(
                "[DLQ] Event #{entry.event_type} exhausted #{@max_retries} retries, dropping. Last error: #{inspect(error)}"
              )

              # Emit algedonic alert for exhausted retries
              try do
                OptimalSystemAgent.Events.Bus.emit_algedonic(
                  :high,
                  "DLQ: #{entry.event_type} handler failed #{@max_retries} times",
                  metadata: %{
                    event_type: entry.event_type,
                    last_error: inspect(error),
                    created_at: entry.created_at
                  }
                )
              rescue
                _ -> :ok
              catch
                _, _ -> :ok
              end

              :exhausted
            else
              backoff =
                min((@base_backoff_ms * :math.pow(2, new_retries)) |> trunc(), @max_backoff_ms)

              updated = %{
                entry
                | retries: new_retries,
                  error: error,
                  next_retry_at: now + backoff
              }

              :ets.insert(@table, {id, updated})
              :retry_later
            end
        end
      end)

    successes = Enum.count(results, &(&1 == :success))
    failures = length(results) - successes
    {successes, failures}
  end

  defp retry_handler(%{handler: {mod, fun, args}} = entry) do
    try do
      apply(mod, fun, args ++ [entry.payload])
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp retry_handler(entry) do
    try do
      entry.handler.(entry.payload)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp to_mfa({_mod, _fun, _args} = mfa), do: mfa

  defp to_mfa(fun) when is_function(fun) do
    case Function.info(fun) do
      info ->
        mod = Keyword.get(info, :module)
        name = Keyword.get(info, :name)

        if mod && name && name != :"-fun" && not String.contains?(Atom.to_string(name), "/") do
          {mod, name, []}
        else
          # Can't convert anonymous function to MFA — store as-is (best effort)
          fun
        end
    end
  end

  defp to_mfa(other), do: other

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
