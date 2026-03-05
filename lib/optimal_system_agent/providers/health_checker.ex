defmodule OptimalSystemAgent.Providers.HealthChecker do
  @moduledoc """
  Circuit breaker and rate-limit tracker for LLM providers.

  ## Circuit Breaker States

    - `:closed`    — provider is healthy, requests flow normally
    - `:open`      — provider has failed repeatedly; requests are skipped
    - `:half_open` — cooldown expired; next request is a probe

  ## Thresholds

    - Opens after 3 consecutive failures
    - Half-opens after 30 seconds of being open
    - Closes after 1 successful request in `:half_open` state

  ## Rate Limiting

  HTTP 429 responses put the provider into a `:rate_limited` sub-state for 60 seconds
  (or the Retry-After duration if provided).  During this window `is_available?/1` returns
  false so the fallback chain skips the provider without burning another attempt.

  ## Usage

      HealthChecker.record_success(:anthropic)
      HealthChecker.record_failure(:groq, :timeout)
      HealthChecker.record_rate_limited(:openai, 30)
      HealthChecker.is_available?(:anthropic)   # => true / false
  """

  use GenServer
  require Logger

  @failure_threshold 3
  @open_timeout_ms 30_000
  @default_rate_limit_ms 60_000

  # --- Public API ---

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Record a successful provider call. Closes the circuit if it was half-open."
  @spec record_success(atom()) :: :ok
  def record_success(provider) do
    GenServer.cast(__MODULE__, {:success, provider})
  end

  @doc "Record a failed provider call. Opens the circuit after #{@failure_threshold} consecutive failures."
  @spec record_failure(atom(), term()) :: :ok
  def record_failure(provider, reason) do
    GenServer.cast(__MODULE__, {:failure, provider, reason})
  end

  @doc """
  Record that the provider returned HTTP 429.

  Marks the provider as rate-limited for `retry_after_seconds` (default 60).
  """
  @spec record_rate_limited(atom(), non_neg_integer() | nil) :: :ok
  def record_rate_limited(provider, retry_after_seconds \\ nil) do
    wait_ms = if is_integer(retry_after_seconds) and retry_after_seconds > 0,
      do: retry_after_seconds * 1_000,
      else: @default_rate_limit_ms

    GenServer.cast(__MODULE__, {:rate_limited, provider, wait_ms})
  end

  @doc """
  Returns `true` if the provider is available for requests.

  Returns `false` when:
  - Circuit is `:open` (and cooldown has not expired)
  - Provider is rate-limited (and rate-limit window has not expired)
  """
  @spec is_available?(atom()) :: boolean()
  def is_available?(provider) do
    GenServer.call(__MODULE__, {:is_available, provider})
  end

  @doc "Return the current circuit state map for all tracked providers (for debugging/monitoring)."
  @spec state() :: map()
  def state do
    GenServer.call(__MODULE__, :state)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    Logger.info("[Providers.HealthChecker] Circuit breaker started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:success, provider}, state) do
    entry = Map.get(state, provider, empty_entry())

    updated =
      case entry.circuit do
        :half_open ->
          Logger.info("[HealthChecker] #{provider}: circuit closed (probe succeeded)")
          %{entry | circuit: :closed, consecutive_failures: 0}

        _ ->
          %{entry | consecutive_failures: 0}
      end

    {:noreply, Map.put(state, provider, updated)}
  end

  def handle_cast({:failure, provider, reason}, state) do
    entry = Map.get(state, provider, empty_entry())
    new_failures = entry.consecutive_failures + 1

    updated =
      if new_failures >= @failure_threshold and entry.circuit != :open do
        Logger.warning(
          "[HealthChecker] #{provider}: circuit OPENED after #{new_failures} consecutive failures " <>
            "(last reason: #{inspect(reason)})"
        )

        %{entry |
          circuit: :open,
          consecutive_failures: new_failures,
          opened_at: System.monotonic_time(:millisecond)
        }
      else
        %{entry | consecutive_failures: new_failures}
      end

    {:noreply, Map.put(state, provider, updated)}
  end

  def handle_cast({:rate_limited, provider, wait_ms}, state) do
    entry = Map.get(state, provider, empty_entry())
    until = System.monotonic_time(:millisecond) + wait_ms

    Logger.warning(
      "[HealthChecker] #{provider}: rate-limited for #{div(wait_ms, 1_000)}s"
    )

    updated = %{entry | rate_limited_until: until}
    {:noreply, Map.put(state, provider, updated)}
  end

  @impl true
  def handle_call({:is_available, provider}, _from, state) do
    entry = Map.get(state, provider, empty_entry())
    now = System.monotonic_time(:millisecond)

    {available, updated_entry} = check_availability(entry, now, provider)

    new_state =
      if updated_entry == entry,
        do: state,
        else: Map.put(state, provider, updated_entry)

    {:reply, available, new_state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # --- Private ---

  defp empty_entry do
    %{
      circuit: :closed,
      consecutive_failures: 0,
      opened_at: nil,
      rate_limited_until: nil
    }
  end

  # Check rate-limit first (independent of circuit state), then circuit state.
  defp check_availability(entry, now, provider) do
    # Check rate limit
    if entry.rate_limited_until && now < entry.rate_limited_until do
      remaining_s = div(entry.rate_limited_until - now, 1_000)
      Logger.debug("[HealthChecker] #{provider}: rate-limited for #{remaining_s}s more")
      {false, entry}
    else
      entry = if entry.rate_limited_until && now >= entry.rate_limited_until,
        do: %{entry | rate_limited_until: nil},
        else: entry

      check_circuit(entry, now, provider)
    end
  end

  defp check_circuit(%{circuit: :closed} = entry, _now, _provider), do: {true, entry}

  defp check_circuit(%{circuit: :open, opened_at: opened_at} = entry, now, provider) do
    if now - opened_at >= @open_timeout_ms do
      Logger.info("[HealthChecker] #{provider}: circuit half-open (cooldown expired)")
      updated = %{entry | circuit: :half_open}
      {true, updated}
    else
      remaining_s = div(@open_timeout_ms - (now - opened_at), 1_000)
      Logger.debug("[HealthChecker] #{provider}: circuit open, skipping (#{remaining_s}s left)")
      {false, entry}
    end
  end

  defp check_circuit(%{circuit: :half_open} = entry, _now, _provider), do: {true, entry}
end
