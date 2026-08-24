defmodule OptimalSystemAgent.Providers.RegistryProviderResolutionTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry

  describe "provider_for_model/1" do
    test "resolves Claude models to :anthropic" do
      assert Registry.provider_for_model("claude-sonnet-4-6") == :anthropic
    end

    test "resolves GPT models to :openai" do
      assert Registry.provider_for_model("gpt-4o") == :openai
    end

    test "resolves Grok models to :xai" do
      assert Registry.provider_for_model("grok-4") == :xai
    end

    test "returns nil for an unattributable model" do
      assert Registry.provider_for_model("totally-made-up-model-zzz") == nil
    end
  end

  describe "known_model?/2" do
    test "accepts any tag for local providers" do
      assert Registry.known_model?(:ollama, "whatever:latest")
    end

    test "accepts a catalog-known cloud model" do
      assert Registry.known_model?(:anthropic, "claude-sonnet-4-6")
    end

    test "rejects an unknown model for a catalog-known provider" do
      refute Registry.known_model?(:anthropic, "claude-not-real-xyz")
    end
  end

  describe "effective_context_window/2" do
    # Pin the ":cloud" window resolution so it is deterministic. For an Ollama
    # Cloud tag, Registry probes the live daemon's /api/show FIRST and only falls
    # back to the static catalog on a miss. That makes the resolved window depend
    # on the environment: a running daemon reports glm-5.2's real trained length
    # (1,048,576) while a CI box with no daemon uses the catalog's 1,000,000 — and
    # the ETS probe cache is process-global, so whichever sibling test probed the
    # model first pinned the value for the rest of the run (the order/seed flake).
    #
    # Seeding the probe cache with the catalog window (the value these assertions
    # document as the meter denominator) pins the resolution input directly, so
    # the network/daemon/cache-leak variable is removed without weakening intent:
    # 1M is still the trained window, still >> the 128k output cap, still not the
    # 32k local ceiling. Cleaned up on exit so it doesn't leak to other modules.
    @cloud_model "glm-5.2:cloud"
    @cloud_window 1_000_000

    setup do
      if :ets.whereis(:osa_context_cache) == :undefined do
        :ets.new(:osa_context_cache, [:set, :public, :named_table])
      end

      prev =
        case :ets.lookup(:osa_context_cache, @cloud_model) do
          [{_, v}] -> {:some, v}
          [] -> :none
        end

      :ets.insert(:osa_context_cache, {@cloud_model, @cloud_window})

      on_exit(fn ->
        case :ets.whereis(:osa_context_cache) do
          :undefined ->
            :ok

          _ ->
            case prev do
              {:some, v} -> :ets.insert(:osa_context_cache, {@cloud_model, v})
              :none -> :ets.delete(:osa_context_cache, @cloud_model)
            end
        end
      end)

      :ok
    end

    test "advertises the 1M window for a 1M-capable Claude model by default" do
      assert Registry.effective_context_window("claude-sonnet-4-6", :anthropic) == 1_000_000
    end

    test "caps the advertised window to 200K when 1M context is disabled" do
      Application.put_env(:optimal_system_agent, :disable_1m_context, true)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :disable_1m_context) end)

      assert Registry.effective_context_window("claude-sonnet-4-6", :anthropic) == 200_000
    end

    test "floors a local model's window at the :ollama_num_ctx ceiling" do
      prev = Application.get_env(:optimal_system_agent, :ollama_num_ctx)
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 8_192)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :ollama_num_ctx, prev),
          else: Application.delete_env(:optimal_system_agent, :ollama_num_ctx)
      end)

      assert Registry.effective_context_window("gpt-4o", :ollama) == 8_192
    end

    test "does NOT cap an Ollama Cloud (:cloud) model to the local num_ctx ceiling" do
      # Regression: glm-5.2:cloud is served via the :ollama provider (the local
      # daemon proxies it to Ollama's hosted hardware) but runs REMOTELY with its
      # full 1M window. It must keep that window, NOT collapse to the tiny local
      # KV-cache ceiling — otherwise the context meter divides usage by ~32k
      # instead of 1M and reads ~30x too high, filling almost instantly.
      prev = Application.get_env(:optimal_system_agent, :ollama_num_ctx)
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 32_768)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :ollama_num_ctx, prev),
          else: Application.delete_env(:optimal_system_agent, :ollama_num_ctx)
      end)

      # The meter denominator must be the true context window (1M), not the local
      # ceiling (32k) and definitely not the model's OUTPUT cap (128k).
      window = Registry.effective_context_window("glm-5.2:cloud", :ollama)
      assert window == 1_000_000
      assert window == Registry.context_window("glm-5.2:cloud")
      refute window == 32_768
      refute window == OptimalSystemAgent.Providers.ModelLimits.max_output("glm-5.2:cloud")
    end

    test "meter denominator is the context window, not the output cap, across providers" do
      # The context-usage meter must always divide by the CONTEXT WINDOW, never the
      # (much smaller) per-model OUTPUT cap — mixing them up is what makes the bar
      # fill too fast.
      for {model, provider, window} <- [
            {"glm-5.2:cloud", :ollama, 1_000_000},
            {"claude-sonnet-4-6", :anthropic, 1_000_000},
            {"gpt-4o", :openai, 128_000}
          ] do
        assert Registry.effective_context_window(model, provider) == window

        assert Registry.effective_context_window(model, provider) >
                 OptimalSystemAgent.Providers.ModelLimits.max_output(model)
      end
    end
  end
end
