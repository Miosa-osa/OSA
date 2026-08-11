defmodule OptimalSystemAgent.Agent.TokenAccountingFidelityTest do
  @moduledoc """
  The compaction decision rests on one number: how many tokens the next request
  will occupy in the model's context window. Three independent defects made
  that number wrong, in two directions:

    1. `Loop.Accounting` published `input_tokens` alone as `last_input_tokens`,
       but Anthropic reports cache-write and cache-read tokens as SEPARATE
       fields — so the better prompt caching works, the smaller the number
       compaction reads, until compaction stops firing at all.
    2. `Utils.Tokens.estimate/1` was whitespace-blind: `words * 1.3` on a
       payload with no whitespace (base64, a minified bundle, a hex dump)
       under-counts by 10-100x, precisely on the tool results big enough to
       blow the window.
    3. `Compactor.estimate_tokens/1` flattened structured content with
       `Jason.encode!/1`, so an inline image was measured by the length of its
       base64 envelope — an order of magnitude MORE than the provider bills.

  These tests assert the numbers, not merely that the functions return.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Utils.Tokens

  # ── One physical prompt, two provider dialects ─────────────────────────────
  #
  # 152,000 real prompt tokens. Anthropic (`Providers.Anthropic.extract_usage/1`)
  # splits it three ways and puts only the uncached tail in `input_tokens`;
  # OpenAI-compatible (`Providers.OpenAICompat.parse_usage/1`) folds the whole
  # prompt into `prompt_tokens` -> `input_tokens` and omits the cache fields.
  @anthropic_shape %{
    "input_tokens" => 2_000,
    "output_tokens" => 800,
    "cache_creation_input_tokens" => 10_000,
    "cache_read_input_tokens" => 140_000
  }

  @openai_shape %{input_tokens: 152_000, output_tokens: 800}

  @real_prompt_tokens 152_000
  @context_window 200_000

  setup do
    # Accounting.record/2 bridges real usage into the *global* Budget ledger.
    # Zero it after each test so recorded spend cannot leak into unrelated
    # tests under random ordering.
    on_exit(fn ->
      if Process.whereis(OptimalSystemAgent.Budget) do
        OptimalSystemAgent.Budget.reset_daily()
        OptimalSystemAgent.Budget.reset_monthly()
        OptimalSystemAgent.Budget.get_status()
      end
    end)

    :ok
  end

  defp base_state do
    %{
      session_id: "tokfid-#{System.unique_integer([:positive])}",
      model: "claude-3-5-sonnet",
      provider: :anthropic,
      last_input_tokens: 0,
      session_cost_usd: 0.0,
      session_input_tokens: 0,
      session_output_tokens: 0,
      session_cache_creation_tokens: 0,
      session_cache_read_tokens: 0,
      max_budget_usd: nil
    }
  end

  # The estimator exactly as it stood before the byte floor was added. Kept
  # verbatim so every "before" number below is a measurement, not a memory.
  defp legacy_estimate(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    punctuation = Regex.scan(~r/[^\w\s]/, text) |> length()
    round(words * 1.3 + punctuation * 0.5)
  end

  defp base64_payload(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode64()

  defp anthropic_image(bytes \\ 120_000) do
    %{
      type: "image",
      source: %{type: "base64", media_type: "image/png", data: base64_payload(bytes)}
    }
  end

  defp openai_image(bytes \\ 120_000) do
    %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:image/png;base64," <> base64_payload(bytes)}
    }
  end

  # ===========================================================================
  # Defect 1 — provider usage shapes must agree on context occupancy
  # ===========================================================================

  describe "Accounting.effective_input_tokens/1" do
    test "both provider shapes yield the same effective total" do
      anthropic = Accounting.effective_input_tokens(@anthropic_shape)
      openai = Accounting.effective_input_tokens(@openai_shape)

      assert anthropic == @real_prompt_tokens
      assert openai == @real_prompt_tokens

      assert anthropic == openai,
             "the same 152k-token prompt must measure the same on both providers, " <>
               "got anthropic=#{anthropic} openai=#{openai}"
    end

    test "the old input_tokens-only reading was 76x low on the Anthropic shape" do
      # The defect, pinned: `input_tokens` alone saw 2,000 of a real 152,000 —
      # and that number SHRINKS as prompt caching gets more effective.
      naive = Accounting.normalize_usage(@anthropic_shape).input_tokens

      assert naive == 2_000
      assert Accounting.effective_input_tokens(@anthropic_shape) == @real_prompt_tokens
      assert div(@real_prompt_tokens, naive) == 76
    end

    test "tolerates nil, string keys, and negative values" do
      assert Accounting.effective_input_tokens(nil) == 0
      assert Accounting.effective_input_tokens(%{}) == 0

      assert Accounting.effective_input_tokens(%{
               "input_tokens" => -5,
               "cache_read_input_tokens" => 100
             }) == 100
    end
  end

  describe "Accounting.record/2 — last_input_tokens" do
    test "an Anthropic usage map with large cache_read produces a LARGE last_input_tokens" do
      # The regression test for the original bug: cache_read dominates and
      # input_tokens is tiny. Before the fix this wrote 2,000.
      state = Accounting.record(base_state(), @anthropic_shape)

      assert state.last_input_tokens == @real_prompt_tokens
    end

    test "both provider shapes drive last_input_tokens to the same value" do
      anthropic = Accounting.record(base_state(), @anthropic_shape)
      openai = Accounting.record(base_state(), @openai_shape)

      assert anthropic.last_input_tokens == openai.last_input_tokens
      assert anthropic.last_input_tokens == @real_prompt_tokens
    end

    test "per-kind session counters still track each slice separately" do
      # The effective total is for context pressure; the per-kind counters feed
      # pricing, which bills cache reads at a different rate. Folding them
      # together in the counters would be a different bug.
      state = Accounting.record(base_state(), @anthropic_shape)

      assert state.session_input_tokens == 2_000
      assert state.session_cache_creation_tokens == 10_000
      assert state.session_cache_read_tokens == 140_000
    end

    test "a fully-cached round-trip still refreshes last_input_tokens" do
      # input_tokens == 0 on a total cache hit. The old `input > 0` guard left
      # last_input_tokens stale at its previous value.
      state =
        Accounting.record(base_state(), %{
          "input_tokens" => 0,
          "output_tokens" => 50,
          "cache_read_input_tokens" => 90_000
        })

      assert state.last_input_tokens == 90_000
    end
  end

  describe "Defect 1 consequence — the compaction decision" do
    test "the effective total crosses the compaction threshold the naive one misses" do
      naive = Accounting.normalize_usage(@anthropic_shape).input_tokens
      effective = Accounting.effective_input_tokens(@anthropic_shape)

      # 152k against a 200k window (180k effective) is ~84% full — real pressure.
      assert CompactionThresholds.used_percent(effective, @context_window) > 70.0

      # 2k of the same window is ~1% — the session sails on into a hard context
      # error instead of compacting.
      assert CompactionThresholds.used_percent(naive, @context_window) < 5.0

      assert Compactor.severity_for(effective, @context_window) != :none
      assert Compactor.severity_for(naive, @context_window) == :none
    end
  end

  # ===========================================================================
  # Defect 2 — the estimator must not be whitespace-blind
  # ===========================================================================

  describe "Utils.Tokens.estimate/1 — whitespace-poor payloads" do
    test "a 160KB base64 blob is estimated in the tens of thousands, not thousands" do
      payload = base64_payload(120_000)
      size = byte_size(payload)
      assert size == 160_000

      # Ground truth: BPE on base64 lands at ~3-4 bytes/token (it splits into
      # short alphanumeric fragments), so ~40k-53k real tokens for 160KB.
      real_low = div(size, 4)
      real_high = div(size, 3)

      before = legacy_estimate(payload)
      now = Tokens.estimate(payload)

      # The defect: the old estimate was more than an order of magnitude low.
      assert before < div(real_low, 10),
             "expected the legacy estimate to be >10x low, got #{before} vs #{real_low}"

      # The fix: inside the real range.
      assert now >= real_low
      assert now <= real_high

      assert now / before > 10,
             "fix must correct by more than 10x, got #{before} -> #{now}"
    end

    test "a whitespace-free identifier dump is not collapsed to a handful of tokens" do
      # 5,000 concatenated hex digests: no whitespace, no punctuation. The word
      # heuristic sees exactly one word.
      payload =
        Enum.map_join(1..5_000, "", fn _ ->
          :crypto.strong_rand_bytes(32) |> Base.encode16()
        end)

      size = byte_size(payload)
      assert size == 320_000

      assert legacy_estimate(payload) < 10,
             "the whole point: the old heuristic saw a single word here"

      assert Tokens.estimate(payload) >= div(size, 4)
    end

    test "the byte floor holds for every payload, whitespace or not" do
      for payload <- [
            base64_payload(1_000),
            String.duplicate("a", 10_000),
            String.duplicate("{\"k\":\"v\"},", 2_000),
            "hello world"
          ] do
        assert Tokens.estimate(payload) >= div(byte_size(payload), 4),
               "byte floor violated for a #{byte_size(payload)}-byte payload"
      end
    end
  end

  describe "Utils.Tokens.estimate/1 — ordinary prose is unchanged" do
    @prose String.duplicate("The quick brown fox jumps over the lazy dog. ", 400)

    test "the word heuristic still wins for English prose" do
      assert Tokens.estimate(@prose) == legacy_estimate(@prose),
             "the byte floor is a floor — it must not perturb prose"
    end

    test "prose stays within a sane factor of a real BPE count" do
      # 3,600 words; English BPE runs ~1.3 tokens/word, so ~4,700 real tokens.
      real = 4_700
      estimate = Tokens.estimate(@prose)

      assert estimate > real * 0.8
      assert estimate < real * 1.2
    end

    test "small inputs are unharmed" do
      assert Tokens.estimate("") == 0
      assert Tokens.estimate(nil) == 0
      assert Tokens.estimate(:not_a_string) == 0
      assert Tokens.estimate("hi") == 1
    end
  end

  describe "Defect 2 consequence — a huge tool result triggers compaction" do
    test "one 160KB base64 tool result registers as real context pressure" do
      blob = base64_payload(120_000)

      messages = [
        %{role: "user", content: "read that file for me"},
        %{role: "tool", content: blob}
      ]

      percent = Compactor.utilization_percent(messages, @context_window)

      assert percent > 15.0,
             "one giant tool result must move the utilization needle, got #{percent}%"

      # Before the fix the same history scored under 2%.
      assert legacy_estimate(blob) / @context_window * 100 < 2.0
    end
  end

  # ===========================================================================
  # Defect 3 — images cost what the provider bills, not what base64 weighs
  # ===========================================================================

  describe "Compactor.estimate_tokens/1 — image blocks" do
    test "a 160KB inline image costs ~1.6k tokens, not ~40k" do
      content = [%{type: "text", text: "what is in this screenshot?"}, anthropic_image()]
      estimate = Compactor.estimate_tokens([%{role: "user", content: content}])

      # Providers bill an image by pixel area: Anthropic ~(w*h)/750 capped near
      # 1600, OpenAI a fixed base plus per-tile cost in the same band. 750-2000
      # covers every realistic screenshot.
      assert estimate > 750
      assert estimate < 2_000

      # The defect, measured: flatten the same content to JSON and run the text
      # heuristic over it, which is what the old code path did.
      flattened = Tokens.estimate(Jason.encode!(content))

      assert flattened > 35_000

      assert flattened / estimate > 15,
             "expected the base64 envelope to over-state by >15x, got #{flattened} vs #{estimate}"
    end

    test "the OpenAI image_url dialect is recognised too" do
      estimate = Compactor.estimate_tokens([%{role: "user", content: [openai_image()]}])

      assert estimate > 750
      assert estimate < 2_000
    end

    test "image cost scales with image COUNT, not with payload size" do
      one = Compactor.estimate_tokens([%{role: "user", content: [anthropic_image(120_000)]}])

      two =
        Compactor.estimate_tokens([
          %{role: "user", content: [anthropic_image(120_000), anthropic_image(120_000)]}
        ])

      # Two images cost exactly double one image, over the shared 4-token frame.
      assert two - one == one - 4

      # A 10x larger encoding of ONE image costs the same as the small one.
      big = Compactor.estimate_tokens([%{role: "user", content: [anthropic_image(1_200_000)]}])
      assert big == one
    end

    test "text alongside an image is still counted" do
      long_text = String.duplicate("describe this diagram carefully. ", 200)

      with_text =
        Compactor.estimate_tokens([
          %{role: "user", content: [%{type: "text", text: long_text}, anthropic_image()]}
        ])

      image_only = Compactor.estimate_tokens([%{role: "user", content: [anthropic_image()]}])

      assert with_text - image_only == Tokens.estimate(long_text)
    end

    test "an image nested inside a tool_result is not re-inflated" do
      msg = %{
        role: "tool",
        content: [
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_1",
            "content" => [
              %{"type" => "text", "text" => "screenshot captured"},
              openai_image()
            ]
          }
        ]
      }

      estimate = Compactor.estimate_tokens([msg])

      assert estimate > 750
      assert estimate < 2_000
    end

    test "plain-string content is untouched by the block walker" do
      assert Compactor.estimate_tokens([%{role: "user", content: "hello world"}]) ==
               Tokens.estimate("hello world") + 4
    end

    test "a thinking block is charged for its reasoning text, not its signature" do
      # Anthropic thinking blocks (`Providers.Anthropic.extract_thinking/1`,
      # rebuilt for the next request at anthropic.ex:808-813) carry an opaque
      # base64 `signature` that is metadata, not billed content. With a byte
      # floor in the heuristic, JSON-encoding the block charges that envelope in
      # full.
      reasoning = String.duplicate("Let me reconsider the constraint here. ", 20)
      signature = base64_payload(1_500)

      block = %{type: "thinking", thinking: reasoning, signature: signature}

      estimate = Compactor.estimate_tokens([%{role: "assistant", content: [block]}])
      text_only = Tokens.estimate(reasoning)
      flattened = Tokens.estimate(Jason.encode!(block))

      # Charged for the reasoning, plus the 4-token message frame.
      assert estimate == text_only + 4

      # The signature envelope alone is an order of magnitude larger.
      assert flattened > 500
      assert flattened > estimate * 2
    end

    test "a redacted_thinking block is charged flat, not by its opaque payload" do
      block = %{"type" => "redacted_thinking", "data" => base64_payload(4_000)}

      estimate = Compactor.estimate_tokens([%{role: "assistant", content: [block]}])
      flattened = Tokens.estimate(Jason.encode!(block))

      assert flattened > 1_300
      assert estimate < 300, "opaque redacted payload must not be billed as text"
      assert estimate > 4, "…but it is not free either"
    end

    test "message-level :thinking_blocks are counted at all" do
      # `ReactLoop` stores thinking blocks as a TOP-LEVEL :thinking_blocks key
      # (react_loop.ex:1011-1013), not inside :content — and they are replayed
      # into the next request, so they occupy context. estimate_tokens/1 counted
      # :content and :tool_calls only, so this was invisible.
      reasoning = String.duplicate("weighing the alternatives carefully. ", 50)

      plain = Compactor.estimate_tokens([%{role: "assistant", content: "ok"}])

      with_thinking =
        Compactor.estimate_tokens([
          %{
            role: "assistant",
            content: "ok",
            thinking_blocks: [
              %{type: "thinking", thinking: reasoning, signature: base64_payload(1_500)}
            ]
          }
        ])

      assert with_thinking - plain == Tokens.estimate(reasoning),
             "replayed thinking must be counted, and counted as its text"
    end

    test "a binary :reasoning_content field is counted" do
      reasoning = String.duplicate("deepseek style reasoning trace. ", 40)

      plain = Compactor.estimate_tokens([%{role: "assistant", content: "ok"}])

      with_reasoning =
        Compactor.estimate_tokens([
          %{role: "assistant", content: "ok", reasoning_content: reasoning}
        ])

      assert with_reasoning - plain == Tokens.estimate(reasoning)
    end

    test "unrecognised block shapes still fall back to encode-and-measure" do
      # Not an image guard — a guard that the walker did not silently start
      # DROPPING content whose shape it does not recognise.
      msg = %{role: "user", content: [%{"weird" => String.duplicate("payload", 500)}]}

      assert Compactor.estimate_tokens([msg]) > 500
    end
  end
end
