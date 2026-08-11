defmodule OptimalSystemAgent.Events.DLQ do
  @moduledoc """
  Dead Letter Queue for failed event handler dispatches.

  When an event handler crashes or times out, the event is placed in
  the DLQ for retry with exponential backoff. After `max_retries`
  failures, an algedonic alert is emitted and the event is dropped.

  Backed by ETS for speed — no persistence across restarts (events
  are ephemeral by design; the learning engine captures durable patterns).

  ## Retryability

  Retrying re-`apply`s the original handler, so every side effect the handler
  performed before failing (file writes, messages, spend) happens again. Errors
  that cannot succeed on a second attempt — budget exhausted, permission denied,
  bad credentials — are therefore never retried: `Healing.ErrorClassifier`
  classifies the error and non-retryable entries go straight to the dead list
  (`dead_entries/0`) with the classification recorded in `:dead_reason`.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Healing.ErrorClassifier

  @table :osa_dlq
  @dead_table :osa_dlq_dead
  @max_retries 3
  @max_dead 100
  @base_backoff_ms 1_000
  @max_backoff_ms 30_000
  @cleanup_interval_ms 60_000

  defstruct [
    :id,
    :event_type,
    :payload,
    :handler,
    :error,
    :retries,
    :next_retry_at,
    :created_at,
    :dead_reason
  ]

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

    case classify(error) do
      {:retryable, _category} ->
        :ets.insert(@table, {entry.id, entry})
        Logger.warning("[DLQ] Enqueued failed #{event_type} event: #{inspect(error)}")
        :ok

      {:dead, category} ->
        # Never re-apply a handler whose failure cannot be fixed by trying
        # again — the retry would only replay the handler's side effects.
        record_dead(entry, category)
        :ok
    end
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

  @doc """
  List entries that were retired without retrying (or without further retries)
  because their error was classified non-retryable. `:dead_reason` holds the
  `ErrorClassifier` category.
  """
  @spec dead_entries() :: [%__MODULE__{}]
  def dead_entries do
    :ets.tab2list(@dead_table) |> Enum.map(fn {_id, entry} -> entry end)
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
    :ets.new(@dead_table, [:named_table, :public, :set])
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
        case classify(entry.error) do
          # Non-retryable: retire without re-applying the handler, so its side
          # effects are not replayed.
          {:dead, category} ->
            :ets.delete(@table, id)
            record_dead(entry, category)
            :dead

          {:retryable, _category} ->
            attempt_retry(id, entry, now)
        end
      end)

    successes = Enum.count(results, &(&1 == :success))
    failures = length(results) - successes
    {successes, failures}
  end

  defp attempt_retry(id, entry, now) do
    case retry_handler(entry) do
      :ok ->
        :ets.delete(@table, id)
        :success

      {:error, error} ->
        case classify(error) do
          {:dead, category} ->
            :ets.delete(@table, id)
            record_dead(%{entry | error: error}, category)
            :dead

          {:retryable, _category} ->
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
    end
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

  # Ask `Healing.ErrorClassifier` whether re-`apply`ing the handler could ever
  # succeed. The DLQ used to retry EVERY error up to @max_retries, so a handler
  # that wrote a file or sent a message before erroring replayed those effects
  # on each attempt — even for errors the classifier already knew were fatal
  # (:budget_exceeded, :permission_denied, :unauthorized). The classifier was
  # right there and simply never called.
  defp classify(error) do
    case ErrorClassifier.classify(error) do
      {category, _severity, true} -> {:retryable, category}
      {category, _severity, false} -> {:dead, category}
    end
  rescue
    # A classifier that cannot read the error must not silently unlock retries.
    _ -> {:retryable, :unknown}
  end

  # Retire an entry without (further) retries, keeping it visible for
  # inspection via `dead_entries/0`.
  defp record_dead(entry, category) do
    dead = %{entry | dead_reason: category}
    :ets.insert(@dead_table, {dead.id, dead})

    Logger.error(
      "[DLQ] #{entry.event_type} handler failed with a non-retryable error " <>
        "(#{category}) — retiring without re-applying it: #{inspect(entry.error)}"
    )

    trim_dead()
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Bound the dead list; oldest entries fall off first.
  defp trim_dead do
    entries = :ets.tab2list(@dead_table)

    if length(entries) > @max_dead do
      entries
      |> Enum.map(fn {_id, e} -> e end)
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.drop(@max_dead)
      |> Enum.each(fn e -> :ets.delete(@dead_table, e.id) end)
    end

    :ok
  rescue
    ArgumentError -> :ok
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
