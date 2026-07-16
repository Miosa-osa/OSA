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
    test "an unresolvable Ollama model is negative-cached so the probe is not repeated" do
      # First call: cannot resolve, falls back to the configured default.
      first = Registry.context_window(@unknown_model)
      assert is_integer(first) and first > 0

      # The miss must now be cached with the sentinel so a subsequent
      # context_window/1 (called on every ReAct iteration) short-circuits
      # instead of re-issuing the blocking /api/show HTTP POST.
      assert [{@unknown_model, :no_ctx}] = :ets.lookup(@cache, @unknown_model)

      # Second call returns the same fallback value and leaves the sentinel in
      # place (served from cache, no network).
      second = Registry.context_window(@unknown_model)
      assert second == first
      assert [{@unknown_model, :no_ctx}] = :ets.lookup(@cache, @unknown_model)
    end

    test "a positive integer already cached is served without probing" do
      :ets.insert(@cache, {@unknown_model, 42_000})
      assert Registry.context_window(@unknown_model) == 42_000
    end
  end
end
