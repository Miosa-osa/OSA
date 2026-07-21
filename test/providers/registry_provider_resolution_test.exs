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
  end
end
