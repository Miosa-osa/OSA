defmodule OptimalSystemAgent.Providers.ModelCatalogSSoTTest do
  @moduledoc """
  Providers.AnthropicModels / Providers.OpenAIModels are the single source of
  truth for their vendors' models.

  These tests exist because the previous arrangement — the same model fact
  hand-copied into 9-14 files — had already drifted in production: the picker
  offered `gpt-5.4-pro`, `gpt-5.2-pro` and `gpt-5.2-chat`, none of which
  appeared in ANY context-window, max-output, pricing or catalog table. A user
  who selected one got a fabricated 128k context budget, no output ceiling and
  $0.00 cost accounting, with nothing anywhere reporting a problem.

  The invariant asserted here is the fix: anything the picker offers must
  resolve end-to-end.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Providers.{AnthropicModels, ModelLimits, OpenAIModels, Registry}

  describe "every offered model resolves end-to-end" do
    test "anthropic picker entries have provider, context, output cap and price" do
      for m <- AnthropicModels.picker_models() do
        assert Registry.provider_for_model(m.id) == :anthropic,
               "#{m.id} must route to :anthropic"

        assert Registry.context_window(m.id) == m.ctx,
               "#{m.id} context window must match the catalog"

        assert is_integer(ModelLimits.max_output(m.id)),
               "#{m.id} must have a max-output cap (nil silently truncates)"

        assert {_in, _out} = Pricing.rates(m.id),
               "#{m.id} must have a price (nil accounts every turn at $0.00)"
      end
    end

    test "openai picker entries have provider, context, output cap and price" do
      for m <- OpenAIModels.picker_models() do
        assert Registry.provider_for_model(m.id) == :openai, "#{m.id} must route to :openai"
        assert Registry.context_window(m.id) == m.ctx
        assert is_integer(ModelLimits.max_output(m.id))
        assert {_in, _out} = Pricing.rates(m.id)
      end
    end
  end

  describe "the models the user asked for are selectable" do
    test "the Claude 5 family plus Haiku 4.5 are in the Anthropic picker" do
      ids = Enum.map(AnthropicModels.picker_models(), & &1.id)

      for id <- ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5"] do
        assert id in ids, "#{id} must be selectable"
      end
    end

    test "the GPT-5.6 family is in the OpenAI picker" do
      ids = Enum.map(OpenAIModels.picker_models(), & &1.id)

      for id <- ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] do
        assert id in ids, "#{id} must be selectable"
      end
    end

    test "no legacy model is offered in a picker" do
      for m <- AnthropicModels.models() ++ OpenAIModels.models(), m.legacy do
        refute m.id in Enum.map(AnthropicModels.picker_models(), & &1.id)
        refute m.id in Enum.map(OpenAIModels.picker_models(), & &1.id)
      end
    end
  end

  describe "published facts" do
    test "Claude 5 family is 1M context / 128k output" do
      for id <- ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"] do
        assert AnthropicModels.context_window(id) == 1_000_000
        assert AnthropicModels.max_output(id) == 128_000
      end
    end

    test "Haiku 4.5 is 200k context / 64k output" do
      assert AnthropicModels.context_window("claude-haiku-4-5") == 200_000
      assert AnthropicModels.max_output("claude-haiku-4-5") == 64_000
    end

    test "GPT-5.6 family is 1.05M context / 128k output" do
      for id <- ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] do
        assert OpenAIModels.context_window(id) == 1_050_000
        assert OpenAIModels.max_output(id) == 128_000
      end
    end
  end

  describe "id resolution" do
    test "Haiku's dated snapshot id resolves to the same model as its alias" do
      # claude-haiku-4-5-20251001 is the canonical Claude API id; claude-haiku-4-5
      # is the alias. Both must price at {1.00, 5.00} — the dated form used to
      # miss the exact table and fall through to the "claude-haiku" family row,
      # billing it at the retired Haiku 3.5 rate of {0.80, 4.00}.
      assert AnthropicModels.resolve("claude-haiku-4-5-20251001").id == "claude-haiku-4-5"
      assert Pricing.rates("claude-haiku-4-5-20251001") == {1.00, 5.00}
      assert ModelLimits.max_output("claude-haiku-4-5-20251001") == 64_000
    end

    test "the gpt-5.6 alias resolves to Sol" do
      assert OpenAIModels.resolve("gpt-5.6").id == "gpt-5.6-sol"
      assert Registry.context_window("gpt-5.6") == 1_050_000
    end

    test "a longer id is never shadowed by a shorter one" do
      assert OpenAIModels.resolve("gpt-4o-mini").id == "gpt-4o-mini"
    end

    test "unknown ids resolve to nil rather than a plausible guess" do
      assert AnthropicModels.resolve("claude-does-not-exist-9") == nil
      assert OpenAIModels.resolve("gpt-nope-9") == nil
    end
  end

  describe "thinking dialect (a wrong answer here is a 400, not a degraded reply)" do
    test "every 4.6+ Anthropic model is adaptive-only" do
      for id <- [
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-sonnet-4-6"
          ] do
        assert AnthropicModels.thinking_mode(id) == :adaptive,
               "#{id} rejects budget_tokens with a 400"
      end
    end

    test "Haiku 4.5 still takes a token budget" do
      assert AnthropicModels.thinking_mode("claude-haiku-4-5") == :budget
    end

    test "an unknown model defaults to adaptive (the safe direction)" do
      assert AnthropicModels.thinking_mode("claude-something-new") == :adaptive
    end
  end

  describe "OpenAI reasoning flag drives temperature suppression and effort" do
    test "the GPT-5.6 family is recognised as reasoning" do
      for id <- ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] do
        assert OpenAIModels.reasoning?(id),
               "#{id} rejects temperature and needs reasoning_effort — the old " <>
                 "o1/o3/o4 prefix scan missed it because the name starts with 'gpt'"
      end
    end

    test "o-series still recognised, including ids not in the table" do
      assert OpenAIModels.reasoning?("o3")
      assert OpenAIModels.reasoning?("o4-mini")
      assert OpenAIModels.reasoning?("o1-preview")
    end

    test "non-reasoning models are not swept in" do
      refute OpenAIModels.reasoning?("gpt-4o")
      refute OpenAIModels.reasoning?("deepseek-reasoner")
    end
  end

  describe "catalog hygiene" do
    test "no model carries a guessed price" do
      for m <- AnthropicModels.models() ++ OpenAIModels.models() do
        assert match?({_, _}, m.pricing) or is_nil(m.pricing)
      end
    end

    test "exactly one recommended model per provider" do
      assert Enum.count(AnthropicModels.picker_models(), & &1.recommended) == 1
      assert Enum.count(OpenAIModels.picker_models(), & &1.recommended) == 1
    end

    test "the default model is one of the offered models" do
      assert AnthropicModels.default_model() in Enum.map(AnthropicModels.picker_models(), & &1.id)
      assert OpenAIModels.default_model() in Enum.map(OpenAIModels.picker_models(), & &1.id)
    end

    test "ids are unique" do
      anthropic_ids = AnthropicModels.ids()
      openai_ids = OpenAIModels.ids()
      assert length(Enum.uniq(anthropic_ids)) == length(anthropic_ids)
      assert length(Enum.uniq(openai_ids)) == length(openai_ids)
    end
  end
end
