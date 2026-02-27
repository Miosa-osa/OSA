defmodule OptimalSystemAgent.Sidecar.CircuitBreaker do
  @moduledoc """
  Per-sidecar circuit breaker for fault isolation.

  State machine: `:closed` → `:open` → `:half_open`

  - **closed**: Normal operation. Failures increment a counter.
  - **open**: After `@failure_threshold` consecutive failures, the circuit opens.
    All calls are rejected immediately for `@recovery_timeout_ms`.
  - **half_open**: After the recovery timeout, one probe request is allowed through.
    If it succeeds → closed. If it fails → back to open.

  State is stored in ETS (`:osa_circuit_breakers`) for lock-free reads.
  """

  @table :osa_circuit_breakers
  @failure_threshold 5
  @recovery_timeout_ms 30_000

  @type state :: :closed | :open | :half_open
  @type entry :: {module(), state(), non_neg_integer(), integer()}

  @doc "Initialize the circuit breaker ETS table. Idempotent."
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Check if a call is allowed through the circuit breaker."
  @spec allow?(module()) :: boolean()
  def allow?(name) when is_atom(name) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [] ->
        # No entry = never failed = closed
        true

      [{^name, :closed, _failures, _ts}] ->
        true

      [{^name, :open, _failures, opened_at}] ->
        now = System.monotonic_time(:millisecond)

        if now - opened_at >= @recovery_timeout_ms do
          # Transition to half_open — allow one probe
          :ets.insert(@table, {name, :half_open, 0, now})
          true
        else
          false
        end

      [{^name, :half_open, _failures, _ts}] ->
        # Already probing — block additional requests during probe
        false
    end
  end

  @doc "Record a successful call — resets failure counter, closes circuit."
  @spec record_success(module()) :: :ok
  def record_success(name) when is_atom(name) do
    ensure_table()
    :ets.insert(@table, {name, :closed, 0, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Record a failed call — increments counter, may open circuit."
  @spec record_failure(module()) :: :ok
  def record_failure(name) when is_atom(name) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, name) do
      [] ->
        :ets.insert(@table, {name, :closed, 1, now})

      [{^name, :closed, failures, _ts}] ->
        new_failures = failures + 1

        if new_failures >= @failure_threshold do
          :ets.insert(@table, {name, :open, new_failures, now})
        else
          :ets.insert(@table, {name, :closed, new_failures, now})
        end

      [{^name, :half_open, _failures, _ts}] ->
        # Probe failed — back to open
        :ets.insert(@table, {name, :open, @failure_threshold, now})

      [{^name, :open, failures, _ts}] ->
        :ets.insert(@table, {name, :open, failures, now})
    end

    :ok
  end

  @doc "Get the current state of a circuit breaker."
  @spec state(module()) :: {state(), non_neg_integer()}
  def state(name) when is_atom(name) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [] -> {:closed, 0}
      [{^name, state, failures, _ts}] -> {state, failures}
    end
  end

  @doc "Reset a circuit breaker (e.g., after manual recovery)."
  @spec reset(module()) :: :ok
  def reset(name) when is_atom(name) do
    ensure_table()
    :ets.delete(@table, name)
    :ok
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined -> init()
      _ -> :ok
    end
  end
end
