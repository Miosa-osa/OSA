defmodule OptimalSystemAgent.Providers.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ModelCatalog

  test "includes current Ollama Cloud agent models with context windows" do
    names = ModelCatalog.names_for(:ollama)

    assert "kimi-k2.6:cloud" in names
    assert "kimi-k2-thinking:cloud" in names
    assert "gemini-3-flash-preview" in names
    assert "qwen3-coder:480b-cloud" in names
    assert "qwen3-coder-next:cloud" in names
    assert "qwen3-next:80b-cloud" in names
    assert "mistral-large-3:675b-cloud" in names
    assert "ministral-3:8b-cloud" in names
    assert "deepseek-v4-pro" in names
    assert "deepseek-v4-pro:cloud" in names
    assert "deepseek-v3.1:671b-cloud" in names
    assert {:ok, 256_000} = ModelCatalog.context_window("kimi-k2.6:cloud")
    assert {:ok, 1_000_000} = ModelCatalog.context_window("deepseek-v4-pro")
    assert {:ok, 1_000_000} = ModelCatalog.context_window("deepseek-v4-pro:cloud")
    assert {:ok, 1_000_000} = ModelCatalog.context_window("gemini-3-flash-preview")
    assert {:ok, 256_000} = ModelCatalog.context_window("mistral-large-3:675b-cloud")
    assert {:ok, 256_000} = ModelCatalog.context_window("ministral-3:8b-cloud")
    assert {:ok, 160_000} = ModelCatalog.context_window("deepseek-v3.1:671b-cloud")
  end

  test "includes current OpenAI and Anthropic frontier models" do
    assert "gpt-5.5" in ModelCatalog.names_for(:openai)
    assert "claude-opus-4-7" in ModelCatalog.names_for(:anthropic)
    assert {:ok, 1_000_000} = ModelCatalog.context_window("claude-opus-4-7")
  end

  test "registry returns 1M context for DeepSeek V4 model aliases" do
    assert OptimalSystemAgent.Providers.Registry.context_window("deepseek-v4-pro") == 1_000_000

    assert OptimalSystemAgent.Providers.Registry.context_window("deepseek-v4-pro:cloud") ==
             1_000_000

    assert OptimalSystemAgent.Providers.Registry.context_window("deepseek-v4-flash") == 1_000_000
  end

  test "registry uses the selected default model when no explicit model is present" do
    original_provider = Application.get_env(:optimal_system_agent, :default_provider)
    original_model = Application.get_env(:optimal_system_agent, :default_model)

    Application.put_env(:optimal_system_agent, :default_provider, :ollama)
    Application.put_env(:optimal_system_agent, :default_model, "deepseek-v4-flash")

    try do
      assert OptimalSystemAgent.Providers.Registry.current_model(:ollama) == "deepseek-v4-flash"
      assert OptimalSystemAgent.Providers.Registry.context_window(nil) == 1_000_000
    after
      restore_env(:default_provider, original_provider)
      restore_env(:default_model, original_model)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, value), do: Application.put_env(:optimal_system_agent, key, value)
end
