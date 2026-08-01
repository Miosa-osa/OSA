defmodule OptimalSystemAgent.Providers.ContextWindowCacheTest do
  # async: false — mutates the shared :ollama_url app env and the shared
  # :osa_context_cache ETS table.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry

  @cache :osa_context_cache
  # A model name that is NOT in Registry's static @model_context_windows map and
  # does not prefix-match any known key, forcing the Ollama /api/show fallback.
  @unknown_model "zzz-nonexistent-osa-test-model-xyz"

  setup do
    # The table is created at application boot; create it here too so the test
    # is robust if run in isolation.
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table])
    end

    :ets.delete(@cache, @unknown_model)

    prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
    # Point at a closed port so the /api/show probe fails fast (connection
    # refused) rather than waiting on the 3s receive_timeout.
    Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

    on_exit(fn ->
      if prev_url do
        Application.put_env(:optimal_system_agent, :ollama_url, prev_url)
      else
        Application.delete_env(:optimal_system_agent, :ollama_url)
      end

      :ets.delete(@cache, @unknown_model)
    end)

    :ok
  end

  describe "context_window/1 negative caching" do
    test "an unreachable Ollama is negative-cached with an EXPIRY so the probe is retried later" do
      # First call: cannot resolve, falls back to the configured default.
      first = Registry.context_window(@unknown_model)
      assert is_integer(first) and first > 0

      # The miss must be cached so a subsequent context_window/1 (called on
      # every ReAct iteration) short-circuits instead of re-issuing the blocking
      # /api/show HTTP POST...
      assert [{@unknown_model, {:no_ctx, expires_at}}] = :ets.lookup(@cache, @unknown_model)

      # ...but this was a TRANSPORT failure (connection refused), which is not
      # an answer about the model. It must carry an expiry rather than pinning
      # the window to "unknown" for the life of the BEAM — otherwise one failed
      # probe at startup makes the context meter read a flat 0% forever.
      assert is_integer(expires_at)
      assert expires_at > System.monotonic_time(:millisecond)

      # Second call, within the TTL, is served from cache (no network).
      second = Registry.context_window(@unknown_model)
      assert second == first
      assert [{@unknown_model, {:no_ctx, ^expires_at}}] = :ets.lookup(@cache, @unknown_model)
    end

    test "an EXPIRED transient negative cache entry does not permanently suppress resolution" do
      # Simulate a probe that failed a while ago and has since expired.
      :ets.insert(
        @cache,
        {@unknown_model, {:no_ctx, System.monotonic_time(:millisecond) - 1}}
      )

      # The expired entry must be treated as a miss and re-probed. The probe
      # fails again here (port closed), so a FRESH entry with a NEW future
      # expiry replaces the stale one — proving the retry actually happened.
      assert is_integer(Registry.context_window(@unknown_model))

      assert [{@unknown_model, {:no_ctx, new_expiry}}] = :ets.lookup(@cache, @unknown_model)
      assert new_expiry > System.monotonic_time(:millisecond)
    end

    test "a permanent :no_ctx sentinel (daemon answered, no context_length) is still honoured" do
      # Definitive negative: the daemon replied but reported no context length.
      # That answer will not change, so it is cached forever and short-circuits.
      :ets.insert(@cache, {@unknown_model, :no_ctx})

      assert is_integer(Registry.context_window(@unknown_model))
      assert [{@unknown_model, :no_ctx}] = :ets.lookup(@cache, @unknown_model)
    end

    test "an unresolvable model reports :unknown rather than inventing a window" do
      # The honest lookup that feeds the TUI context meter must never fabricate
      # a denominator — the TUI renders a token count with no percentage.
      :ets.insert(@cache, {@unknown_model, :no_ctx})
      assert Registry.context_window_info(@unknown_model) == :unknown
    end

    test "a positive integer already cached is served without probing" do
      :ets.insert(@cache, {@unknown_model, 42_000})
      assert Registry.context_window(@unknown_model) == 42_000
    end
  end
end
