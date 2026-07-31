defmodule OptimalSystemAgent.Providers.ContextWindowResolutionTest do
  @moduledoc """
  The context meter's denominator must be REAL or absent — never fabricated.

  Root cause these tests lock down: `context_window/1` resolved every model
  through a static table baked into the binary, and `effective_context_window/2`
  explicitly SKIPPED the live `/api/show` probe for Ollama Cloud models — the one
  path that could have returned the truth was disabled exactly where the user
  runs (`glm-5.2:cloud`, `deepseek-v4-flash:cloud`). Anything the table did not
  list fell back to a family PREFIX guess or the flat `:max_context_tokens`
  default, so the TUI divided real usage by a number that had nothing to do with
  the model.
  """
  # async: false — mutates shared app env (:ollama_url, :ollama_num_ctx) and the
  # shared :osa_context_cache ETS table.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry

  @cache :osa_context_cache

  # Not in the static table, no prefix match, not in the Catalog.
  @unknown_model "zzz-nonexistent-osa-ctx-model-xyz"
  @unknown_cloud_model "zzz-nonexistent-osa-ctx-model-xyz:cloud"
  @local_model "zzz-local-osa-ctx-model-xyz:8b"

  setup do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table])
    end

    prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
    prev_num_ctx = Application.get_env(:optimal_system_agent, :ollama_num_ctx)

    # Point the probe at a closed port so it fails fast (connection refused)
    # instead of hitting a real daemon — every test here that wants a probe
    # result seeds the cache directly (the cache IS the probe's memo table).
    Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

    on_exit(fn ->
      restore(:ollama_url, prev_url)
      restore(:ollama_num_ctx, prev_num_ctx)

      for m <- [@unknown_model, @unknown_cloud_model, @local_model, "glm-5.2:cloud"] do
        :ets.delete(@cache, m)
      end
    end)

    for m <- [@unknown_model, @unknown_cloud_model, @local_model, "glm-5.2:cloud"] do
      :ets.delete(@cache, m)
    end

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  # Seeding the memo table is how the /api/show probe is mocked: `get_ollama_context/1`
  # reads this table before issuing any HTTP request, so a seeded entry is
  # indistinguishable from a successful probe (and no network is touched).
  defp mock_probe(model, ctx), do: :ets.insert(@cache, {model, ctx})

  describe "known models" do
    test "a catalog/static model resolves to its real window" do
      assert Registry.context_window_info("claude-haiku-4-5") == {:ok, 200_000}
      assert Registry.context_window("claude-haiku-4-5") == 200_000
      assert Registry.context_window_known?("claude-haiku-4-5")

      assert Registry.context_window_info("gpt-4o") == {:ok, 128_000}
      assert Registry.context_window_known?("gpt-4o", :openai)
    end
  end

  describe "cloud models are probed (the fix)" do
    test "a :cloud model takes the PROBED window, not the static table guess" do
      # The static table lists glm-5.2 at 1M via prefix match. If the live probe
      # says otherwise, the probe wins — it is the model's actual context_length.
      mock_probe("glm-5.2:cloud", 262_144)

      assert Registry.context_window_info("glm-5.2:cloud") == {:ok, 262_144}
      assert Registry.effective_context_window_info("glm-5.2:cloud", :ollama) == {:ok, 262_144}

      # ...and the cloud model is still never squeezed under the LOCAL num_ctx
      # ceiling (it runs on Ollama's hardware, not this machine's KV cache).
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 8_192)
      assert Registry.effective_context_window("glm-5.2:cloud", :ollama) == 262_144
    end

    test "a :cloud model unknown to the static table resolves from the probe" do
      # Before the fix this fell straight through to the 128k config default.
      mock_probe(@unknown_cloud_model, 524_288)

      assert Registry.context_window_info(@unknown_cloud_model) == {:ok, 524_288}
      assert Registry.effective_context_window(@unknown_cloud_model, :ollama) == 524_288
      assert Registry.context_window_known?(@unknown_cloud_model, :ollama)
    end

    test "a failed cloud probe falls back to the static table, never crashes" do
      # No cache entry + unreachable URL => probe fails, static prefix match wins.
      assert {:ok, window} = Registry.context_window_info("glm-5.2:cloud")
      assert window == 1_000_000
    end
  end

  describe "unknown models report :unknown instead of a fabricated default" do
    test "context_window_info/1 is :unknown when nothing knows the model" do
      assert Registry.context_window_info(@unknown_model) == :unknown
      assert Registry.effective_context_window_info(@unknown_model, :ollama) == :unknown
      refute Registry.context_window_known?(@unknown_model)
      refute Registry.context_window_known?(@unknown_model, :ollama)
    end

    test "the lossy context_window/1 contract is preserved for existing callers" do
      # Token budgeting / num_ctx sizing still need *a* number; only the
      # percentage-rendering surfaces switched to the :unknown-aware API.
      default = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      assert Registry.context_window(@unknown_model) == default
    end

    test "nil / non-binary models are unknown" do
      assert Registry.context_window_info(nil) == :unknown
      assert Registry.effective_context_window_info(nil, :ollama) == :unknown
      refute Registry.context_window_known?(nil)
    end
  end

  describe "local models" do
    test "window is min(real context_length, num_ctx ceiling)" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 32_768)

      # Real trained window smaller than the ceiling => the real window wins.
      mock_probe(@local_model, 8_192)
      assert Registry.effective_context_window_info(@local_model, :ollama) == {:ok, 8_192}
      assert Registry.effective_context_window(@local_model, :ollama) == 8_192

      # Real trained window larger than the ceiling => the ceiling wins (that is
      # the num_ctx OSA actually allocates).
      :ets.delete(@cache, @local_model)
      mock_probe(@local_model, 262_144)
      assert Registry.effective_context_window(@local_model, :ollama) == 32_768
    end
  end

  describe "forget_context_window/1 (model switch re-resolves)" do
    test "drops a cached probe result so the next lookup re-resolves" do
      mock_probe(@unknown_cloud_model, 524_288)
      assert Registry.context_window_info(@unknown_cloud_model) == {:ok, 524_288}

      assert Registry.forget_context_window(@unknown_cloud_model) == :ok
      assert :ets.lookup(@cache, @unknown_cloud_model) == []

      # With the cache dropped and the probe unreachable, an unknown model is
      # honestly unknown again rather than stuck on the stale value.
      assert Registry.context_window_info(@unknown_cloud_model) == :unknown
    end

    test "drops a stale NEGATIVE cache entry (probe failed while daemon was down)" do
      assert Registry.context_window_info(@unknown_cloud_model) == :unknown
      assert [{@unknown_cloud_model, :no_ctx}] = :ets.lookup(@cache, @unknown_cloud_model)

      Registry.forget_context_window(@unknown_cloud_model)
      assert :ets.lookup(@cache, @unknown_cloud_model) == []

      # A re-probe that now succeeds is honored — the model is not pinned to the
      # fabricated default for the rest of the session.
      mock_probe(@unknown_cloud_model, 131_072)
      assert Registry.context_window_info(@unknown_cloud_model) == {:ok, 131_072}
    end

    test "is a no-op for nil / unseen models" do
      assert Registry.forget_context_window(nil) == :ok
      assert Registry.forget_context_window("never-seen-model") == :ok
    end
  end
end
