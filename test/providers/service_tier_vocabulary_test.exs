defmodule OptimalSystemAgent.Providers.ServiceTierVocabularyTest do
  @moduledoc """
  A processing tier is a per-provider word, not a portable one.

  `priority` is OpenAI's, `performance` is Groq's, `standard_only` is
  Anthropic's. The agent loop resolves ONE tier for the turn, so without a
  check at each provider boundary one provider's vocabulary is forwarded raw to
  another, where an unrecognized `service_tier` is a validation error rather
  than an ignored field. The turn then pays for a rejected request plus the
  tier-less retry behind it, every turn, for acceleration the account never
  receives.

  Anthropic already had the allowlist (see `anthropic_service_tier_test.exs`);
  these are the boundaries that did not.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Bedrock
  alias OptimalSystemAgent.Providers.Google
  alias OptimalSystemAgent.Providers.OpenAICompat

  @msgs [%{role: "user", content: "hi"}]

  describe "OpenAI-compatible routes" do
    test "OpenAI keeps its own documented vocabulary" do
      for tier <- ["auto", "default", "flex", "priority", "scale"] do
        body =
          OpenAICompat.build_stream_body("gpt-5", @msgs, provider: :openai, service_tier: tier)

        assert body.service_tier == tier
      end
    end

    test "Groq keeps the words Groq defines" do
      for tier <- ["auto", "on_demand", "flex", "performance"] do
        body = OpenAICompat.build_stream_body("llama", @msgs, provider: :groq, service_tier: tier)

        assert body.service_tier == tier
      end
    end

    test "a tier from another provider is dropped, not forwarded" do
      dropped = [
        {:groq, "priority"},
        {:groq, "standard_only"},
        {:openai, "on_demand"},
        {:openai, "performance"},
        {:openai, "standard_only"}
      ]

      for {provider, tier} <- dropped do
        body =
          OpenAICompat.build_stream_body("m", @msgs, provider: provider, service_tier: tier)

        refute Map.has_key?(body, :service_tier),
               "#{provider} should not be sent #{tier}"
      end
    end

    test "providers with no verified vocabulary are sent no tier at all" do
      for provider <- [:xai, :openrouter, :lmstudio, :ollama] do
        body =
          OpenAICompat.build_stream_body("m", @msgs, provider: provider, service_tier: "priority")

        refute Map.has_key?(body, :service_tier)
      end
    end
  end

  describe "providers whose tier wire format was never verified" do
    test "Gemini requests carry no serviceTier" do
      body = Google.build_request_body(@msgs, "gemini-3-pro", service_tier: "priority")

      refute Map.has_key?(body, :serviceTier)
      refute Map.has_key?(body, "serviceTier")
    end

    test "Bedrock Converse requests carry no serviceTier" do
      body =
        Bedrock.build_request_body(@msgs, "anthropic.claude-opus-5", service_tier: "priority")

      refute Map.has_key?(body, "serviceTier")
      refute Map.has_key?(body, :serviceTier)
      # The rest of the body is untouched by the removal.
      assert is_list(body["messages"])
    end
  end
end
