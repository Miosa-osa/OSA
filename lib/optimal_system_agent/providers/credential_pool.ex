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

  defstruct pools: %{}, counters: %{}

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

    {:ok, %__MODULE__{pools: pools, counters: %{}}}
  end

  @impl true
  def handle_call({:get_key, provider}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, fallback_key(provider), state}

      keys when is_list(keys) and length(keys) > 0 ->
        counter = Map.get(state.counters, provider, 0)
        now = System.monotonic_time(:millisecond)

        # Find next available key (skip rate-limited)
        {key, next_counter} = find_available_key(keys, counter, now, length(keys))

        new_counters = Map.put(state.counters, provider, next_counter)
        {:reply, key, %{state | counters: new_counters}}

      _ ->
        {:reply, fallback_key(provider), state}
    end
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

  defp load_all_pools do
    @env_vars
    |> Enum.reduce(%{}, fn {provider, {pool_var, single_var}}, acc ->
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

      keys =
        if keys == [] do
          case System.get_env(single_var) do
            nil -> []
            "" -> []
            key -> [key]
          end
        else
          keys
        end

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
