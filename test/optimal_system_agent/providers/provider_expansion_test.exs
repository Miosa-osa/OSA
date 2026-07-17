defmodule OptimalSystemAgent.Providers.ProviderExpansionTest do
  @moduledoc """
  Regression coverage for the provider-expansion wave:

    * The 8 previously-unroutable providers (miosa, xai, cerebras, sambanova,
      hyperbolic, lmstudio, llamacpp, ollama_cloud) now have registry routing —
      selecting them no longer returns "Unknown provider: …".
    * MIOSA Cloud is surfaced as a coming-soon / limited placeholder rather than
      a hard failure.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Onboarding

  @newly_routed [:miosa, :xai, :cerebras, :sambanova, :hyperbolic, :lmstudio, :llamacpp]

  describe "registry routing (crash fix)" do
    test "every newly-routed provider is registered" do
      providers = Registry.list_providers()

      for p <- [:ollama_cloud | @newly_routed] do
        assert p in providers, "expected #{p} to be registered"
      end
    end

    test "provider_info succeeds for each newly-routed provider" do
      for p <- @newly_routed do
        assert {:ok, info} = Registry.provider_info(p), "provider_info failed for #{p}"
        assert is_binary(info.default_model) and info.default_model != ""
      end
    end

    test "ollama_cloud routes to the native Ollama module" do
      assert {:ok, info} = Registry.provider_info(:ollama_cloud)
      assert info.module == OptimalSystemAgent.Providers.Ollama
    end

    test "selecting :miosa no longer crashes with 'Unknown provider'" do
      # No MIOSA_API_KEY in the test env → a graceful key error, NOT the old
      # "Unknown provider: miosa" routing crash. This is the core bug fix.
      assert {:error, reason} =
               Registry.chat([%{role: "user", content: "hi"}], provider: :miosa, max_tokens: 1)

      assert is_binary(reason)
      refute reason =~ "Unknown provider"
      assert reason =~ "MIOSA_API_KEY"
    end

    test "a genuinely unknown provider still returns 'Unknown provider'" do
      assert {:error, reason} =
               Registry.chat([%{role: "user", content: "hi"}], provider: :zzz_not_real)

      assert reason =~ "Unknown provider"
    end

    test "provider_configured?/1 is a boolean for the new providers" do
      for p <- [:ollama_cloud | @newly_routed] do
        assert is_boolean(Registry.provider_configured?(p))
      end
    end
  end

  describe "onboarding catalog overlay" do
    test "MIOSA is a top coming-soon / limited placeholder" do
      miosa = Enum.find(Onboarding.providers_list(), &(&1.id == "miosa"))
      assert miosa.group == "recommended"
      assert miosa.status == "coming_soon"
      assert miosa.availability == :limited
      assert is_binary(miosa.badge)
    end

    test "Ollama Cloud is in the recommended group" do
      cloud = Enum.find(Onboarding.providers_list(), &(&1.id == "ollama_cloud"))
      assert cloud.group == "recommended"
      assert cloud.recommended == true
    end

    test "OpenRouter is promoted to the recommended group" do
      openrouter = Enum.find(Onboarding.providers_list(), &(&1.id == "openrouter"))
      assert openrouter.group == "recommended"
    end
  end

  describe "MIOSA health_check gating" do
    test "returns a friendly coming-soon notice, not a hard failure" do
      assert {:ok, result} = Onboarding.health_check(%{"provider" => "miosa"})
      assert result.status == "coming_soon"
      assert result.availability == "limited"
      assert is_binary(result.message)
    end
  end

  describe "model_list is catalog-backed for static providers" do
    test "openai models come from the catalog with ctx + capability flags" do
      assert {:ok, models} = Onboarding.model_list("openai")
      assert models != []
      gpt4o = Enum.find(models, &(&1.id == "gpt-4o"))
      assert gpt4o.ctx == 128_000
      assert gpt4o.tools == true
    end
  end
end
