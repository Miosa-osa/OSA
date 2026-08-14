defmodule OptimalSystemAgent.Agent.PricingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Pricing

  describe "rates/1" do
    test "prices the default GLM cloud model" do
      assert {0.60, 2.20} = Pricing.rates("glm-5.2:cloud")
    end

    test "matches known families by substring (case-insensitive)" do
      assert {3.0, 15.0} = Pricing.rates("claude-3-5-sonnet-20241022")
      assert {2.5, 10.0} = Pricing.rates("GPT-4o")
    end

    test "local ollama-hosted models are free" do
      assert Pricing.rates("ollama/llama3.1") == {0.0, 0.0}
      assert Pricing.rates("qwen2.5:7b") == {0.0, 0.0}
    end

    test "unknown model returns nil (never guessed)" do
      assert is_nil(Pricing.rates("totally-made-up-model-x"))
    end

    test "nil model returns nil" do
      assert is_nil(Pricing.rates(nil))
    end
  end

  # ── Gateway-prefixed model ids (the ~2.5x over-accounting) ──────────────
  #
  # OSA reaches Claude/GLM/DeepSeek through OpenRouter in the benchmarks, and
  # OpenRouter names models `<vendor>/<id>`. Those strings matched no catalog
  # key and fell through to the coarse `@families` substring table.
  # Reconciled against a real run (bench/swebenchpro/runs/or-opus5-probe3):
  # 1,534,954 in / 9,929 out on `anthropic/claude-opus-5` was billed
  # $23.768985 — exactly `in*15 + out*75` per 1M, exactly 3x the real
  # {5.00, 25.00}.
  describe "rates/1 with a gateway vendor prefix" do
    test "anthropic/claude-opus-5 prices as claude-opus-5, not the Opus 3 family rate" do
      assert Pricing.rates("anthropic/claude-opus-5") == Pricing.rates("claude-opus-5")
      assert {5.00, 25.00} = Pricing.rates("anthropic/claude-opus-5")
      refute Pricing.rates("anthropic/claude-opus-5") == {15.0, 75.0}
    end

    test "the prefixed id is priced identically to the bare id for every gateway model" do
      for id <- ~w(claude-opus-5 claude-sonnet-5 claude-haiku-4-5 gpt-5.6-sol deepseek-v4-pro) do
        for vendor <- ~w(anthropic openai deepseek z-ai) do
          assert Pricing.rates(vendor <> "/" <> id) == Pricing.rates(id),
                 "#{vendor}/#{id} priced differently from #{id}"
        end
      end
    end

    test "a prefixed id no longer under-accounts at $0.00 or at a retired rate" do
      # Both were live under-counts, the opposite direction from the Opus 3x.
      assert Pricing.rates("openai/gpt-5.6-sol") == Pricing.rates("gpt-5.6-sol")
      refute is_nil(Pricing.rates("openai/gpt-5.6-sol"))
      assert Pricing.rates("deepseek/deepseek-v4-pro") == Pricing.rates("deepseek-v4-pro")
      refute Pricing.rates("deepseek/deepseek-v4-pro") == {0.27, 1.10}
    end

    # The gateway spells the VERSION with a dot; the vendor catalog uses a
    # dash. `anthropic/claude-haiku-4.5` is the id OpenRouter actually serves,
    # and it matched neither the exact map nor the catalog prefix — it fell to
    # the "claude-haiku" family guess {0.80, 4.0}, the retired Haiku 3.5 rate,
    # billing 20% UNDER the published {1.00, 5.00}. That is the route the
    # Anthropic benchmark arm runs on, so the $/task it published was low.
    test "a dotted gateway version resolves to the dashed catalog id" do
      assert {1.00, 5.00} = Pricing.rates("anthropic/claude-haiku-4.5")
      assert Pricing.rates("anthropic/claude-haiku-4.5") == Pricing.rates("claude-haiku-4-5")
      refute Pricing.rates("anthropic/claude-haiku-4.5") == {0.80, 4.0}
      assert Pricing.confidence("anthropic/claude-haiku-4.5") == :exact
    end

    test "a genuinely dotted key still resolves on its own spelling first" do
      # The dashed rewrite is tried LAST; these must not move.
      assert {0.63, 1.98} = Pricing.rates("z-ai/glm-5.2")
      assert {0.60, 2.20} = Pricing.rates("glm-5.2:cloud")
      assert {2.0, 8.0} = Pricing.rates("gpt-4.1")
      assert {0.15, 0.60} = Pricing.rates("gpt-4o-mini")
    end

    test "a real colon-tagged id still wins on the full string" do
      # `:cloud` is model identity; `:free`/`:nitro` are OpenRouter routing.
      assert {0.60, 2.20} = Pricing.rates("glm-5.2:cloud")
      assert Pricing.rates("anthropic/claude-opus-5:floor") == Pricing.rates("claude-opus-5")
    end

    test "an unknown prefixed model is still never guessed" do
      assert is_nil(Pricing.rates("acme/totally-made-up-model-x"))
    end

    test "the real or-opus5-probe3 turn reconciles to the provider rate" do
      usage = %{input_tokens: 1_534_954, output_tokens: 9_929}
      # What OSA recorded for this instance, at the wrong family rate.
      assert_in_delta 23.768985,
                      (1_534_954 * 15.0 + 9_929 * 75.0) / 1_000_000,
                      0.000_01

      # What it should have been, and now is.
      assert_in_delta Pricing.cost("anthropic/claude-opus-5", usage), 7.923, 0.001
    end
  end

  describe "cost/2" do
    test "computes input + output cost per 1M tokens" do
      # 1M input @ $3, 1M output @ $15 => $18 for sonnet
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert Pricing.cost("claude-3-5-sonnet", usage) == 18.0
    end

    test "applies cache-write x1.25 and cache-read x0.1 multipliers off input rate" do
      # input rate $3/1M. 1M cache-write => 3 * 1.25 = 3.75. 1M cache-read => 3 * 0.1 = 0.3
      usage = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000
      }

      assert Pricing.cost("claude-3-5-sonnet", usage) == 4.05
    end

    test "unknown model costs $0.0" do
      usage = %{input_tokens: 5_000_000, output_tokens: 5_000_000}
      assert Pricing.cost("no-such-model", usage) == 0.0
    end

    test "tolerates string-keyed usage maps" do
      usage = %{"input_tokens" => 1_000_000, "output_tokens" => 0}
      assert Pricing.cost("glm-5.2:cloud", usage) == 0.60
    end
  end

  # The `@families` substring table is a guess by construction. `"claude-opus"
  # => {15, 75}` was right for Claude 3 Opus and 3x wrong for Opus 5, and that
  # single row is the whole of the 2.487x by which a benchmark run over-reported
  # its own spend. The vendor-prefix fix closed the door for `claude-opus-5`; it
  # cannot close it for the next unknown `claude-opus-N`. So a fall-through must
  # be visible — structurally, not just in a log line nobody greps.
  describe "confidence/1 — an estimate must announce itself as one" do
    test "a catalog / SSOT hit is :exact" do
      assert Pricing.confidence("claude-opus-5") == :exact
      assert Pricing.confidence("anthropic/claude-opus-5") == :exact
      assert Pricing.confidence("glm-5.2:cloud") == :exact
    end

    test "a family-table fall-through is :estimated, not :exact" do
      # No catalog knows this id, but "claude-opus" matches the family table.
      assert Pricing.confidence("claude-opus-99") == :estimated
      # ...and it still returns a (guessed) rate rather than nothing, because an
      # over-estimate is more useful to a budget cap than $0.00.
      assert Pricing.rates("claude-opus-99") == {15.0, 75.0}
    end

    test "no rate at all is :unknown, and costs $0.0" do
      assert Pricing.confidence("no-such-model-anywhere") == :unknown
      assert Pricing.cost("no-such-model-anywhere", %{input_tokens: 1_000_000}) == 0.0
    end

    test "nil / non-string models are :unknown rather than raising" do
      assert Pricing.confidence(nil) == :unknown
      assert Pricing.confidence(42) == :unknown
    end

    test "confidence/1 does not itself emit the family warning" do
      # It is called from display paths; only real pricing should be loud.
      Pricing.reset_family_warnings()
      log = ExUnit.CaptureLog.capture_log(fn -> Pricing.confidence("claude-opus-98") end)
      refute log =~ "ESTIMATED price"
    end
  end

  describe "cost_with_confidence/2" do
    test "carries the qualifier alongside the dollar figure" do
      usage = %{input_tokens: 1_000_000, output_tokens: 0}

      assert {3.0, :exact} = Pricing.cost_with_confidence("claude-3-5-sonnet", usage)
      assert {15.0, :estimated} = Pricing.cost_with_confidence("claude-opus-97", usage)
      assert {+0.0, :unknown} = Pricing.cost_with_confidence("no-such-model-anywhere", usage)
    end
  end

  describe "the family fall-through is LOUD" do
    test "names the model and says the price is a guess" do
      Pricing.reset_family_warnings()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Pricing.cost("claude-opus-96", %{input_tokens: 1_000})
        end)

      assert log =~ "claude-opus-96"
      assert log =~ "ESTIMATED"
      assert log =~ "SUBSTRING GUESS"
    end

    test "warns once per model, not once per round-trip" do
      Pricing.reset_family_warnings()

      first =
        ExUnit.CaptureLog.capture_log(fn ->
          Pricing.cost("claude-opus-95", %{input_tokens: 1_000})
        end)

      second =
        ExUnit.CaptureLog.capture_log(fn ->
          Pricing.cost("claude-opus-95", %{input_tokens: 1_000})
        end)

      assert first =~ "claude-opus-95"
      # A warning repeated 400x a session is noise nobody reads, which is
      # functionally the same as being silent.
      refute second =~ "claude-opus-95"
    end
  end
end
