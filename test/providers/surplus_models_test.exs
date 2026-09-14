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

  describe "with_speed/1" do
    # Globally-unique ids, and no `ModelSpeed.reset/0` call here — this file
    # runs async, so it must never touch keys any other test might depend on.
    # Uniqueness alone is what makes concurrent access to the same underlying
    # persistent_term-backed store safe.
    test "attaches nil when the model has never been measured" do
      row = %{
        id: "surplus-models-test-with-speed-unmeasured-#{System.unique_integer([:positive])}"
      }

      assert SurplusModels.with_speed(row).tok_s == nil
    end

    test "attaches the measured tok/s from ModelSpeed when a real turn has recorded one" do
      id = "surplus-models-test-with-speed-measured-#{System.unique_integer([:positive])}"
      OptimalSystemAgent.Providers.ModelSpeed.record(:surplus, id, 123.4)

      assert SurplusModels.with_speed(%{id: id}).tok_s == 123.4
    end

    test "picker_models/0 rows carry a :tok_s key (nil until measured)" do
      [row | _] = SurplusModels.picker_models()
      assert Map.has_key?(row, :tok_s)
    end
  end
end
