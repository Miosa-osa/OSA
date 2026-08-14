defmodule OptimalSystemAgent.Agent.CompactorContextWindowTest do
  @moduledoc """
  Regression tests for the "compacts far too early on large-window models" bug.

  `Agent.Compactor` read a flat
  `Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)` and
  was never handed the real per-model window at ANY of its three call sites
  (`Loop.handle_call(:compact, ...)`, `TurnPipeline.compact_and_refresh_tokens/1`,
  `ReactLoop.handle_result/3`'s overflow fallback). On a 1M-token model that
  fired a full LLM summarization pass at ~11% of the real window, repeatedly,
  permanently destroying conversation fidelity — while the status bar (already
  fixed to use the real window) correctly reported 11%.

  The bug shipped because nothing asserted that the model's window ever reached
  the compaction decision. These tests assert exactly that.
  """
  # async: false — reads/clears the global :max_context_tokens operator override.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.ContextWindow
  alias OptimalSystemAgent.Providers.Registry

  @million 1_000_000
  @thirty_two_k 32_768

  setup do
    prev = Application.get_env(:optimal_system_agent, :max_context_tokens)

    # The operator override must be ABSENT for these tests: the whole point is
    # that the window arrives from the caller, not from global config.
    Application.delete_env(:optimal_system_agent, :max_context_tokens)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :max_context_tokens, prev),
        else: Application.delete_env(:optimal_system_agent, :max_context_tokens)
    end)

    # A history large enough that the pipeline has real work to do when it fires.
    filler = String.duplicate("lorem ipsum dolor sit amet consectetur adipiscing elit ", 40)

    messages =
      Enum.flat_map(1..60, fn i ->
        [
          %{role: "user", content: "turn #{i} question: #{filler}"},
          %{role: "assistant", content: "turn #{i} answer: #{filler}"}
        ]
      end)

    {:ok, messages: messages}
  end

  # ---------------------------------------------------------------------------
  # THE BUG: a large window must not compact at small occupancy
  # ---------------------------------------------------------------------------

  describe "1M-token window" do
    # These used to be expressed as PERCENTAGES of the raw window (15/30/50%),
    # which was the right unit while every threshold scaled linearly with the
    # window. `CompactionThresholds.operative_window/1` now clamps that window
    # to 200,000 before any threshold is derived, so on a 1M model the ladder is
    # warn 147,000 / compact 167,000 / block 177,000 in ABSOLUTE tokens and a
    # percentage of 1M no longer names a point on it — 30% of 1M is 300,000,
    # which is past the blocking limit, not "nowhere near full".
    #
    # The clamp is deliberate and is the fix for the defect this file's
    # moduledoc describes only half of: the 128k default made OSA compact far
    # too EARLY, and removing it made a 1M model compact at 967,000 — i.e.
    # never, since a session that large is unreachable. Both are the same bug
    # (thresholds not connected to reality); the ceiling is what bounds it at
    # both ends.
    #
    # So the property being pinned is unchanged — a large-window model must not
    # be summarized while its context is still small — but it is now stated in
    # the unit the decision is actually made in.
    for used <- [50_000, 100_000, 140_000] do
      test "does NOT compact at #{used} tokens", %{messages: messages} do
        used = unquote(used)

        assert Compactor.severity_for(used, @million) == :none,
               "#{used} tokens is below warn_at(1M) = #{CompactionThresholds.warn_at(@million)}"

        assert Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @million}) ==
                 messages,
               "a 1M-window model must not be summarized at #{used} tokens"
      end
    end

    test "the clamped ladder is where those numbers come from" do
      # Pins the ceiling itself, so a change to @context_ceiling shows up here
      # as an explicit diff rather than as six mysterious failures above.
      assert CompactionThresholds.operative_window(@million) == 200_000
      assert CompactionThresholds.warn_at(@million) == 147_000
      assert CompactionThresholds.compact_at(@million) == 167_000
      assert CompactionThresholds.block_at(@million) == 177_000

      # And it is a no-op at or below the ceiling — the clamp cannot regress a
      # model that was already working.
      for cw <- [@thirty_two_k, 128_000, 200_000] do
        assert CompactionThresholds.operative_window(cw) == cw
      end
    end

    test "the 128k hardcoded default is gone — 11% of 1M is not treated as 86% of 128k", %{
      messages: messages
    } do
      # 110_000 tokens: ~11% of the real 1M window, but ~86% of the old
      # fabricated 128k default — squarely above the old 0.85 tier that fired.
      used = 110_000

      assert Compactor.severity_for(used, @million) == :none

      refute Compactor.severity_for(used, 128_000) == :none,
             "sanity: this token count WOULD have compacted against the old 128k default"

      assert Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @million}) ==
               messages
    end

    test "still compacts once genuinely full", %{messages: messages} do
      used = CompactionThresholds.compact_at(@million) + 1

      assert Compactor.severity_for(used, @million) in [:aggressive, :emergency]

      # The DECISION is what this pins: at a genuinely-full 1M window the
      # pipeline runs (vs. returning the list untouched at 15/30/50%). The
      # history here is only ~120 short messages, so it is already far under the
      # 1M-window target and no compression STEP has anything to do — the run is
      # observable via the post-compaction restore/reminder append.
      result = Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @million})
      refute result == messages, "a genuinely-full 1M window must run the pipeline"
    end
  end

  # ---------------------------------------------------------------------------
  # A small window must still compact at ITS threshold
  # ---------------------------------------------------------------------------

  describe "32k-token window" do
    test "does not compact below its threshold", %{messages: messages} do
      used = CompactionThresholds.warn_at(@thirty_two_k) - 1

      assert Compactor.severity_for(used, @thirty_two_k) == :none

      assert Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @thirty_two_k}) ==
               messages
    end

    test "DOES compact at its correct threshold", %{messages: messages} do
      used = CompactionThresholds.warn_at(@thirty_two_k)

      assert Compactor.severity_for(used, @thirty_two_k) == :background

      result =
        Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @thirty_two_k})

      assert result != messages, "a 32k window at its warn threshold must compact"
    end

    test "severity escalates through the shared reserve-based thresholds" do
      cw = @thirty_two_k

      assert Compactor.severity_for(CompactionThresholds.warn_at(cw) - 1, cw) == :none
      assert Compactor.severity_for(CompactionThresholds.warn_at(cw), cw) == :background
      assert Compactor.severity_for(CompactionThresholds.compact_at(cw), cw) == :aggressive
      assert Compactor.severity_for(CompactionThresholds.block_at(cw), cw) == :emergency
    end
  end

  # ---------------------------------------------------------------------------
  # The window actually REACHES the decision
  # ---------------------------------------------------------------------------

  describe "the window reaches the decision" do
    test "the same message list compacts for 32k and not for 1M", %{messages: messages} do
      # One token count, two models. Under the bug both were divided by 128_000
      # and produced the same answer — that is exactly what this pins.
      #
      # 100_000, not 500_000: with the 200k operative ceiling, 500,000 tokens is
      # past block_at(1M) = 177,000 and now correctly compacts on BOTH models,
      # which would make the comparison vacuous. 100_000 still sits below
      # warn_at(1M) = 147,000 and far above block_at(32k), so the two models
      # still disagree — which is the whole point.
      used = 100_000

      assert Compactor.severity_for(used, @million) == :none
      assert Compactor.severity_for(used, @thirty_two_k) == :emergency

      unchanged = Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @million})

      compacted =
        Compactor.maybe_compact(messages, used, nil, context_window: {:ok, @thirty_two_k})

      assert unchanged == messages
      assert length(compacted) < length(messages)
      refute compacted == unchanged
    end

    test "a bare integer window is accepted as well as the {:ok, n} registry shape", %{
      messages: messages
    } do
      # 100_000: below warn_at(1M) = 147,000 under the 200k operative ceiling.
      # 500_000 (the old value) is now past block_at and would compact.
      used = 100_000
      assert Compactor.maybe_compact(messages, used, nil, context_window: @million) == messages
      assert Compactor.resolve_window(@million) == {:ok, @million}
      assert Compactor.resolve_window({:ok, @million}) == {:ok, @million}
    end
  end

  # ---------------------------------------------------------------------------
  # :unknown windows are DEFERRED, deterministically
  # ---------------------------------------------------------------------------

  describe "unknown context window" do
    test "resolves to :unknown with no operator override set" do
      assert Compactor.resolve_window(:unknown) == :unknown
      assert Compactor.resolve_window(nil) == :unknown
      assert Compactor.resolve_window(0) == :unknown
      assert Compactor.resolve_window(-1) == :unknown
      assert Compactor.resolve_window("128000") == :unknown
    end

    test "DEFERS compaction rather than guessing a denominator", %{messages: messages} do
      # No matter how large the reported usage, with no known window there is
      # nothing to compare it to. Guessing is what caused the bug; the provider's
      # own context-length error is the signal we wait for.
      for used <- [0, 100_000, 900_000, 5_000_000] do
        assert Compactor.maybe_compact(messages, used, nil, context_window: :unknown) == messages
        assert Compactor.maybe_compact(messages, used, nil, []) == messages
      end
    end

    test "is deterministic — repeated calls never compact", %{messages: messages} do
      for _ <- 1..5 do
        assert Compactor.maybe_compact(messages, 900_000, nil, context_window: :unknown) ==
                 messages
      end
    end

    test "`force: true` compacts anyway — the overflow path's real signal", %{messages: messages} do
      # ReactLoop's overflow fallback passes force: true because the provider has
      # ALREADY returned a context-length error.
      result = Compactor.maybe_compact(messages, 0, nil, context_window: :unknown, force: true)
      assert length(result) < length(messages)
    end

    test "an explicit operator override is honoured when the window is unknown", %{
      messages: messages
    } do
      Application.put_env(:optimal_system_agent, :max_context_tokens, @thirty_two_k)

      assert Compactor.resolve_window(:unknown) == {:ok, @thirty_two_k}

      result =
        Compactor.maybe_compact(messages, @thirty_two_k - 1, nil, context_window: :unknown)

      assert length(result) < length(messages)
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
    end

    test "a KNOWN window always beats the operator override", %{messages: messages} do
      # The override is a fallback for ignorance, never a way for stale config to
      # win over real per-model data.
      Application.put_env(:optimal_system_agent, :max_context_tokens, 8_000)

      assert Compactor.resolve_window({:ok, @million}) == {:ok, @million}

      # 100_000: below warn_at(1M) = 147,000 under the 200k operative ceiling,
      # but wildly above anything an 8,000-token override would tolerate — so
      # the assertion still distinguishes "the real window won" from "the stale
      # override won". 500_000 (the old value) now compacts under BOTH, which
      # would have made this pass for the wrong reason.
      assert Compactor.maybe_compact(messages, 100_000, nil, context_window: {:ok, @million}) ==
               messages
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
    end
  end

  # ---------------------------------------------------------------------------
  # Loop.ContextWindow — the shared, honest resolver the call sites use
  # ---------------------------------------------------------------------------

  describe "Loop.ContextWindow.resolve/1" do
    test "resolves a real large-window model to its real window" do
      state = %{model: "glm-5.2:cloud", provider: :ollama}

      assert {:ok, cw} = ContextWindow.resolve(state)
      assert cw == elem(Registry.effective_context_window_info("glm-5.2:cloud", :ollama), 1)

      # And that window is nowhere near the fabricated 128k default.
      assert cw > 200_000
    end

    test "returns :unknown for a model nobody has heard of — never the 128k default" do
      state = %{
        model: "totally-made-up-model-#{System.unique_integer([:positive])}",
        provider: nil
      }

      assert ContextWindow.resolve(state) == :unknown
    end

    test "returns :unknown for a state with no model" do
      assert ContextWindow.resolve(%{}) == :unknown
      assert ContextWindow.resolve(%{model: nil, provider: :ollama}) == :unknown
      assert ContextWindow.resolve(%{model: "", provider: :ollama}) == :unknown
      assert ContextWindow.resolve(nil) == :unknown
    end

    test "accepts a string provider (the HTTP/JSON path) as well as an atom" do
      atom_state = %{model: "glm-5.2:cloud", provider: :ollama}
      string_state = %{model: "glm-5.2:cloud", provider: "ollama"}

      assert ContextWindow.resolve(atom_state) == ContextWindow.resolve(string_state)
    end

    test "an unparseable provider still resolves through the trained window" do
      state = %{model: "glm-5.2:cloud", provider: "not-a-real-provider-atom"}
      assert {:ok, cw} = ContextWindow.resolve(state)
      assert cw > 200_000
    end
  end

  # ---------------------------------------------------------------------------
  # One definition of "how full is too full"
  # ---------------------------------------------------------------------------

  describe "shared threshold definition" do
    test "severity_for/2 agrees with ProactiveCompaction's compact_at/1" do
      # ProactiveCompaction.should_compact?/2 fires at compact_at/1. The
      # Compactor must be at least as aggressive by then, never earlier for a
      # large window and never later for a small one.
      for cw <- [@thirty_two_k, 128_000, 262_144, @million] do
        at = CompactionThresholds.compact_at(cw)

        assert Compactor.severity_for(at, cw) in [:aggressive, :emergency],
               "cw=#{cw}: compact_at must map to a real compaction tier"

        assert Compactor.severity_for(CompactionThresholds.warn_at(cw) - 1, cw) == :none,
               "cw=#{cw}: nothing below warn_at may compact"
      end
    end

    test "target_tokens/2 is derived from the shared thresholds, not a private ratio" do
      for cw <- [@thirty_two_k, 128_000, @million] do
        assert Compactor.target_tokens(:background, cw) == CompactionThresholds.warn_at(cw)
        assert Compactor.target_tokens(:aggressive, cw) == CompactionThresholds.warn_at(cw)
        assert Compactor.target_tokens(:emergency, cw) < CompactionThresholds.warn_at(cw)
      end

      # A forced compaction with no resolvable window has no budget to aim at.
      assert Compactor.target_tokens(:emergency, :unknown) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # The hardcoded accessor is GONE (it cannot regrow)
  # ---------------------------------------------------------------------------

  test "Compactor exports no hardcoded max_tokens accessor" do
    exports = Compactor.__info__(:functions)

    refute Keyword.has_key?(exports, :max_tokens),
           "Compactor.max_tokens/0 is the defect — a private hardcoded default that " <>
             "silently won over real per-model data. It must not come back."

    refute Keyword.has_key?(exports, :utilization),
           "utilization/1 was unit-ambiguous; use utilization_percent/2"
  end
end
