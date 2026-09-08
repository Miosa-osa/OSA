defmodule OptimalSystemAgent.Providers.SurplusModelsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.SurplusModels
  alias OptimalSystemAgent.Providers.OpenAICompatProvider
  alias OptimalSystemAgent.Providers.Registry

  test "uses a current frontier default from the curated shortlist" do
    assert SurplusModels.default_model() == "claude-fable-5.1"
    assert SurplusModels.default_model() in SurplusModels.ids()
  end

  test "curated shortlist contains the newest models shown by Surplus" do
    ids = SurplusModels.ids()

    assert "claude-fable-5.1" in ids
    assert "gpt-6-astra" in ids
    assert "kimi-k3" in ids
    assert "kimi-k3-fast-api" in ids
    assert "muse-spark-1.3-contributor" in ids
    assert "qwen3.8-flash" in ids
    assert "deepseek-v4-pro" in ids
    assert "mistral-large-3" in ids
    assert "deepseek-v3.1" in ids
  end

  test "provider is wired through the setup catalog and harness registry" do
    provider = Enum.find(OptimalSystemAgent.Onboarding.providers_list(), &(&1.id == "surplus"))

    assert provider.name == "Surplus Intelligence"
    assert provider.env_var == "SURPLUS_API_KEY"
    assert provider.requires_key
    assert provider.default_model == "claude-fable-5.1"
    assert OpenAICompatProvider.base_url(:surplus) == "https://api.surplusintelligence.ai/v1"
    assert OpenAICompatProvider.default_model(:surplus) == "claude-fable-5.1"
    assert {:ok, info} = Registry.provider_info(:surplus)
    assert info.module == OpenAICompatProvider
    assert "gpt-6-astra" in info.available_models
  end

  test "parses Surplus catalog metadata and prices" do
    model =
      SurplusModels.parse(%{
        "id" => "claude-fable-5.1",
        "name" => "Claude Fable 5.1",
        "context_length" => 262_144,
        "supported_parameters" => ["tools"],
        "supported_features" => ["streaming", "reasoning"],
        "pricing" => %{"prompt" => "0.00001", "completion" => "0.000024"}
      })

    assert model.id == "claude-fable-5.1"
    assert model.ctx == 262_144
    assert model.tools
    assert model.reasoning
    assert model.cost == %{input: 10.0, output: 24.0}
    assert model.featured
  end

  test "live catalog ordering keeps curated models first" do
    models = [
      SurplusModels.parse(%{"id" => "zeta", "name" => "Zeta"}),
      SurplusModels.parse(%{"id" => "gpt-6-astra", "name" => "GPT-6 Astra"}),
      SurplusModels.parse(%{"id" => "claude-fable-5.1", "name" => "Claude Fable 5.1"})
    ]

    assert Enum.map(SurplusModels.order_catalog(models), & &1.id) == [
             "claude-fable-5.1",
             "gpt-6-astra",
             "zeta"
           ]
  end
end
