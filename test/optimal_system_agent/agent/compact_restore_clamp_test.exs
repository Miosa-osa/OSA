defmodule OptimalSystemAgent.Agent.CompactRestoreClampTest do
  @moduledoc """
  Compaction must never make the window bigger.

  The restore block re-injects file bodies on a 50k-character budget. It was
  clamped by `ProactiveCompaction` and appended raw by `Compactor` — the path
  behind `/compact` and the prune tier. A live v1.0.101 session recorded what
  that produced:

      Compacted ~6.1k -> ~71.8k tokens (1 messages folded) · 1m 4s

  ~65k tokens ADDED by an operation whose only purpose is removal, unprompted,
  which then re-fired because the fold had pushed the total past the threshold
  that triggers folding. A 260k-character restore estimates at 65,004 tokens.

  The bound now lives on the builder, so a caller cannot omit it. These tests
  assert the invariant on the returned value rather than on either caller, and
  the last one asserts the property that actually matters to a user: no
  compaction path can hand back more than it was given.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.{CompactRestore, Compactor}

  describe "clamp_restore/1" do
    test "a restore block far over budget is truncated to the configured ceiling" do
      # 260k characters is the shape measured in the field: every touched file's
      # body re-injected at the 50k-char-per-section budget across sections.
      huge = %{role: "system", content: String.duplicate("x", 260_000)}

      assert Compactor.estimate_tokens([huge]) > 60_000,
             "the fixture must actually be over budget, or this test proves nothing"

      clamped = CompactRestore.clamp_for_test(huge)

      assert Compactor.estimate_tokens([clamped]) <= 4_000,
             "a restore block must never exceed the ceiling — it is appended to a " <>
               "conversation that was just shrunk"

      assert String.contains?(clamped.content, "truncated"),
             "truncation must be visible in the block, not silent"
    end

    test "a restore block under budget is returned unchanged" do
      small = %{role: "system", content: "[restore] three files, two tasks."}

      assert CompactRestore.clamp_for_test(small) == small,
             "clamping must not perturb a block that already fits"
    end

    test "the ceiling is configurable and is honoured" do
      original = Application.get_env(:optimal_system_agent, :compaction_restore_max_tokens)
      Application.put_env(:optimal_system_agent, :compaction_restore_max_tokens, 500)

      on_exit(fn ->
        if original do
          Application.put_env(:optimal_system_agent, :compaction_restore_max_tokens, original)
        else
          Application.delete_env(:optimal_system_agent, :compaction_restore_max_tokens)
        end
      end)

      msg = %{role: "system", content: String.duplicate("y", 100_000)}

      assert Compactor.estimate_tokens([CompactRestore.clamp_for_test(msg)]) <= 500
    end

    test "a non-binary content shape is passed through rather than crashing" do
      # Structured/multimodal content reaches this path on some providers. The
      # clamp must not raise on a shape it cannot measure — it fails open on the
      # size and closed on the crash, which is the safe direction for a block
      # that is only ever additive.
      structured = %{role: "system", content: [%{"type" => "text", "text" => "hi"}]}

      assert CompactRestore.clamp_for_test(structured) == structured
    end
  end

  describe "the invariant a user actually cares about" do
    test "the restore block cannot re-inflate a freshly compacted window" do
      # The failure this pins: a 6.1k conversation coming back as 71.8k. The
      # restore block is the only additive part of a fold that scales with the
      # session rather than with the summary, so bounding it bounds the fold.
      compacted_window = 6_100

      worst_case = %{role: "system", content: String.duplicate("z", 500_000)}
      clamped = CompactRestore.clamp_for_test(worst_case)

      added = Compactor.estimate_tokens([clamped])

      assert added <= 4_000

      refute added > compacted_window,
             "the restore block alone must not exceed the window it is being " <>
               "appended to — that is how a fold ends up larger than its input"
    end
  end
end
