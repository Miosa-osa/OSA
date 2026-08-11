defmodule OptimalSystemAgent.Providers.CredentialPool do
  @moduledoc """
  API key rotation pool for LLM providers.

  Supports multiple API keys per provider with round-robin rotation and
  automatic skip of rate-limited keys. Keys are loaded from comma-separated
  environment variables (e.g., `ANTHROPIC_API_KEYS=key1,key2,key3`).

  Falls back to the single-key env var if the pool var is not set.
  """
  use GenServer
  require Logger

  @env_vars %{
    anthropic: {"ANTHROPIC_API_KEYS", "ANTHROPIC_API_KEY"},
    openai: {"OPENAI_API_KEYS", "OPENAI_API_KEY"},
    groq: {"GROQ_API_KEYS", "GROQ_API_KEY"},
    together: {"TOGETHER_API_KEYS", "TOGETHER_API_KEY"},
    openrouter: {"OPENROUTER_API_KEYS", "OPENROUTER_API_KEY"},
    google: {"GOOGLE_API_KEYS", "GOOGLE_API_KEY"},
    cohere: {"COHERE_API_KEYS", "COHERE_API_KEY"}
  }

  # Rate limit cooldown: 60 seconds
  @cooldown_ms 60_000

  # `last_issued` records the key `get_key/1` most recently handed out per
  # provider. It exists so the 429 call site does not have to plumb the key back
  # through the provider's error tuple — see `mark_rate_limited/1`.
  # `sources` records the RAW environment strings each provider's pool was
  # built from, so `get_key/1` can notice that the environment has moved out
  # from under the snapshot. See `refresh_if_env_changed/2`.
  defstruct pools: %{}, counters: %{}, last_issued: %{}, sources: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the next available API key for a provider. Returns nil if none available."
  def get_key(provider) do
    GenServer.call(__MODULE__, {:get_key, provider})
  rescue
    _ -> fallback_key(provider)
  catch
    :exit, _ -> fallback_key(provider)
  end

  @doc "Mark a key as rate-limited (will be skipped for @cooldown_ms)."
  def mark_rate_limited(provider, key) do
    GenServer.cast(__MODULE__, {:rate_limited, provider, key})
  end

  @doc """
  Mark the key most recently issued for `provider` as rate-limited.

  This module advertises "automatic skip of rate-limited keys", but nothing ever
  called `mark_rate_limited/2`: a key that returned HTTP 429 kept coming back out
  of `get_key/1` on the very next attempt, so a multi-key pool rotated through
  nothing and the same throttled key absorbed every retry. This arity-1 form is
  what the 429 path can actually call — the provider that sees the response
  holds an opaque `{:api_key, key}` it should not have to unwrap and pass back,
  and `get_key/1` is already serialized through this GenServer, so the pool
  itself is the natural owner of "which key did I just hand out".

  Best-effort by construction: a cast, and a no-op when the pool holds nothing
  for the provider (single-key setups, or the env-var fallback path).
  """
  @spec mark_rate_limited(atom()) :: :ok
  def mark_rate_limited(provider) do
    GenServer.cast(__MODULE__, {:rate_limited_last, provider})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Re-read every pool from the current environment.

  The pools are snapshotted once in `init/1`, and `get_key/1` takes priority
  over `Application.get_env/2` in the providers. So when a user replaced their
  key at runtime (the in-UI key screen, `osa setup` in the same node), the
  pool kept handing back the key captured at boot and the new one never took
  effect — the user saw their *old*, possibly revoked, key rejected no matter
  how many times they re-entered the right one. Call this after any write that
  changes a `*_API_KEY` env var.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Get pool stats for a provider."
  def stats(provider) do
    GenServer.call(__MODULE__, {:stats, provider})
  rescue
    _ -> %{total: 0, available: 0, rate_limited: 0}
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    pools = load_all_pools()

    if map_size(pools) > 0 do
      providers_with_pools =
        pools
        |> Enum.filter(fn {_, keys} -> length(keys) > 1 end)
        |> Enum.map(fn {p, keys} -> "#{p}(#{length(keys)})" end)

      if providers_with_pools != [],
        do: Logger.info("CredentialPool: #{Enum.join(providers_with_pools, ", ")}")
    end

    {:ok, %__MODULE__{pools: pools, counters: %{}, sources: read_sources()}}
  end

  @impl true
  def handle_call({:get_key, provider}, _from, state) do
    state = refresh_if_env_changed(state, provider)

    case Map.get(state.pools, provider) do
      nil ->
        {:reply, fallback_key(provider), state}

      keys when is_list(keys) and length(keys) > 0 ->
        counter = Map.get(state.counters, provider, 0)
        now = System.monotonic_time(:millisecond)

        # Find next available key (skip rate-limited)
        {key, next_counter} = find_available_key(keys, counter, now, length(keys))

        new_counters = Map.put(state.counters, provider, next_counter)
        new_last = Map.put(state.last_issued, provider, key)
        {:reply, key, %{state | counters: new_counters, last_issued: new_last}}

      _ ->
        {:reply, fallback_key(provider), state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Counters are reset alongside the pools: they index into the key list, and
    # a stale offset against a re-read list would skip keys arbitrarily. The
    # last-issued map is dropped for the same reason — it may name a key the
    # re-read pools no longer contain.
    {:reply, :ok,
     %{state | pools: load_all_pools(), counters: %{}, last_issued: %{}, sources: read_sources()}}
  end

  @impl true
  def handle_call({:stats, provider}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, %{total: 0, available: 0, rate_limited: 0}, state}

      keys ->
        now = System.monotonic_time(:millisecond)
        total = length(keys)
        rate_limited = Enum.count(keys, fn {_k, until} -> until && until > now end)

        {:reply, %{total: total, available: total - rate_limited, rate_limited: rate_limited},
         state}
    end
  end

  @impl true
  def handle_cast({:rate_limited_last, provider}, state) do
    case Map.get(state.last_issued, provider) do
      nil -> {:noreply, state}
      key -> handle_cast({:rate_limited, provider, key}, state)
    end
  end

  @impl true
  def handle_cast({:rate_limited, provider, key}, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:noreply, state}

      keys ->
        until = System.monotonic_time(:millisecond) + @cooldown_ms

        updated =
          Enum.map(keys, fn
            {^key, _old} -> {key, until}
            other -> other
          end)

        Logger.warning(
          "CredentialPool: #{provider} key #{mask(key)} rate-limited for #{div(@cooldown_ms, 1000)}s"
        )

        {:noreply, %{state | pools: Map.put(state.pools, provider, updated)}}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Notice, at the moment of use, that this provider's environment no longer
  # matches the snapshot the pool is serving from.
  #
  # `reload/0` closes this correctly but only for the write paths that
  # remember to call it — onboarding's two and `cli/setup`'s one. Every other
  # writer left the pool serving the boot snapshot, and because `get_key/1`
  # OUTRANKS `Application.get_env/2` in the providers, that snapshot wins over
  # the key the user just entered. Two real paths were open:
  #
  #   * `POST /providers/:slug/connect` sets the key env var and then
  #     immediately makes a live test call — which spent the OLD key, so the
  #     verification of a correct new key could fail.
  #   * `DELETE /providers/:slug` deletes the env var, and the pool went on
  #     handing out the key the user had just revoked. That is the dangerous
  #     direction: a credential the operator believes is gone keeps being sent
  #     over the wire.
  #
  # Auditing the writers one at a time only fixes the writers that exist
  # today. Comparing the snapshot against the live environment at the point of
  # use fixes every writer, including ones not written yet, and costs two
  # `System.get_env/1` reads on a call that is already a GenServer round trip.
  #
  # Only the changed provider is rebuilt, so an unrelated provider keeps its
  # round-robin position and its rate-limit cooldowns.
  defp refresh_if_env_changed(state, provider) do
    case Map.get(@env_vars, provider) do
      nil ->
        state

      {pool_var, single_var} = vars ->
        current = {System.get_env(pool_var), System.get_env(single_var)}

        if Map.get(state.sources, provider) == current do
          state
        else
          keys = load_pool(vars)

          pools =
            if keys == [],
              do: Map.delete(state.pools, provider),
              else: Map.put(state.pools, provider, Enum.map(keys, &{&1, nil}))

          Logger.info(
            "CredentialPool: #{provider} credentials changed on disk/env — re-read " <>
              "(#{length(keys)} key(s)); the previous snapshot is discarded."
          )

          %{
            state
            | pools: pools,
              # The counter indexes into the key list and the last-issued key
              # may no longer be in it, so both are meaningless against a
              # re-read pool.
              counters: Map.delete(state.counters, provider),
              last_issued: Map.delete(state.last_issued, provider),
              sources: Map.put(state.sources, provider, current)
          }
        end
    end
  end

  # The raw env strings every pool was built from — the thing compared above.
  # Deliberately the raw values and not a hash: a hash of a secret is still
  # derived from a secret, and this map never leaves the process.
  defp read_sources do
    Map.new(@env_vars, fn {provider, {pool_var, single_var}} ->
      {provider, {System.get_env(pool_var), System.get_env(single_var)}}
    end)
  end

  defp load_pool({pool_var, single_var}) do
    keys =
      case System.get_env(pool_var) do
        nil ->
          []

        "" ->
          []

        val ->
          val
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    if keys == [] do
      case System.get_env(single_var) do
        nil -> []
        "" -> []
        key -> [key]
      end
    else
      keys
    end
  end

  defp load_all_pools do
    @env_vars
    |> Enum.reduce(%{}, fn {provider, vars}, acc ->
      keys = load_pool(vars)

      if keys != [] do
        # Store as {key, rate_limited_until} tuples
        Map.put(acc, provider, Enum.map(keys, fn k -> {k, nil} end))
      else
        acc
      end
    end)
  end

  defp find_available_key(keys, start_counter, now, max_attempts) do
    find_available_key(keys, start_counter, now, max_attempts, 0)
  end

  defp find_available_key(keys, counter, _now, max, attempts) when attempts >= max do
    # All keys are rate-limited — return the next one anyway (cooldown may have expired by the time the request is made)
    idx = rem(counter, length(keys))
    {key, _} = Enum.at(keys, idx)
    {key, counter + 1}
  end

  defp find_available_key(keys, counter, now, max, attempts) do
    idx = rem(counter, length(keys))
    {key, rate_limited_until} = Enum.at(keys, idx)

    if rate_limited_until && rate_limited_until > now do
      # This key is rate-limited — try next
      find_available_key(keys, counter + 1, now, max, attempts + 1)
    else
      {key, counter + 1}
    end
  end

  defp fallback_key(provider) do
    case Map.get(@env_vars, provider) do
      {_pool_var, single_var} -> System.get_env(single_var)
      nil -> nil
    end
  end

  defp mask(key) when is_binary(key) and byte_size(key) > 8 do
    String.slice(key, 0, 4) <> "..." <> String.slice(key, -4, 4)
  end

  defp mask(_key), do: "***"
end
