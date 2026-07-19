defmodule OptimalSystemAgent.Agent.Loop.ProactiveCompactionCCTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.{CompactionThresholds, ProactiveCompaction}

  @cw 200_000

  setup do
    for table <- [:osa_compactor_state, :osa_files_read] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  end

  defp state(tokens, sid \\ nil),
    do: %{last_input_tokens: tokens, messages: [], session_id: sid}

  test "should_compact? fires exactly at the CC reserve threshold" do
    at = CompactionThresholds.compact_at(@cw)
    refute ProactiveCompaction.should_compact?(state(at - 1), @cw)
    assert ProactiveCompaction.should_compact?(state(at), @cw)
  end

  test "should_microcompact? only inside the warning band" do
    warn = CompactionThresholds.warn_at(@cw)
    compact = CompactionThresholds.compact_at(@cw)
    refute ProactiveCompaction.should_microcompact?(state(warn - 1), @cw)
    assert ProactiveCompaction.should_microcompact?(state(warn), @cw)
    refute ProactiveCompaction.should_microcompact?(state(compact), @cw)
  end

  test "circuit breaker opens after 3 consecutive failures" do
    sid = "breaker-#{System.unique_integer([:positive])}"
    :ets.insert(:osa_compactor_state, {{:compact_failures, sid}, 3})
    at = CompactionThresholds.compact_at(@cw)
    refute ProactiveCompaction.should_compact?(state(at + 1, sid), @cw)
  end

  test "strip_analysis removes scratchpad and extracts summary" do
    raw =
      "<analysis>secret drafting</analysis>\n<summary>\n1. Primary Request: fix bug\n</summary>"

    formatted = ProactiveCompaction.strip_analysis(raw)
    refute formatted =~ "secret drafting"
    assert formatted =~ "Summary:"
    assert formatted =~ "1. Primary Request: fix bug"
  end

  test "compact/2 folds older turns, injects compact boundary, resets breaker" do
    sid = "compact-#{System.unique_integer([:positive])}"
    :ets.insert(:osa_compactor_state, {{:compact_failures, sid}, 2})

    filler = String.duplicate("lorem ipsum dolor sit amet consectetur ", 60)

    messages =
      Enum.flat_map(1..8, fn i ->
        [
          %{role: "user", content: "turn #{i}: #{filler}"},
          %{role: "assistant", content: "reply #{i}: #{filler}"}
        ]
      end)

    compacted = ProactiveCompaction.compact(messages, sid)

    assert length(compacted) < length(messages)
    [first | _] = compacted
    assert first.role == "system"
    assert first.content =~ "[Compact boundary]"
    assert first.content =~ "being continued from a previous conversation"

    # success reset the failure counter
    assert :ets.lookup(:osa_compactor_state, {:compact_failures, sid}) == []
  end

  test "compact restore re-injects file contents within budget" do
    sid = "restore-#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "osa-restore-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "MAGIC_RESTORE_CONTENT " <> String.duplicate("x", 10_000))
    :ets.insert(:osa_files_read, {{sid, path}, true})

    msg = OptimalSystemAgent.Agent.CompactRestore.build_restore_message(sid)
    assert msg.content =~ "MAGIC_RESTORE_CONTENT"
    assert msg.content =~ "(truncated)"

    File.rm(path)
  end

  describe "continuation_message/1 (post-compaction auto-continue)" do
    test "normal case: plain continue turn, synthetic + marked" do
      msg = ProactiveCompaction.continuation_message()

      assert msg.role == "user"
      assert msg.synthetic == true
      assert msg.metadata == %{compaction_continue: true, overflow: false}
      assert msg.content =~ "Continue if you have next steps"
      refute msg.content =~ "exceeded the provider's context window"
    end

    test "overflow case: prepends media/overflow explanation before the continue text" do
      msg = ProactiveCompaction.continuation_message(overflow: true)

      assert msg.role == "user"
      assert msg.synthetic == true
      assert msg.metadata == %{compaction_continue: true, overflow: true}
      assert msg.content =~ "exceeded the provider's context window"
      assert msg.content =~ "media attachments were removed"
      assert msg.content =~ "Continue if you have next steps"

      # overflow explanation must come BEFORE the generic continue text
      overflow_pos = :binary.match(msg.content, "context window") |> elem(0)
      continue_pos = :binary.match(msg.content, "Continue if you have next steps") |> elem(0)
      assert overflow_pos < continue_pos
    end

    test "continuation_enabled?/0 defaults to true and respects config override" do
      assert ProactiveCompaction.continuation_enabled?() == true

      Application.put_env(:optimal_system_agent, :proactive_compaction_auto_continue, false)
      refute ProactiveCompaction.continuation_enabled?()
    after
      Application.delete_env(:optimal_system_agent, :proactive_compaction_auto_continue)
    end

    test "composes with (does not replace) the active-agent reminder: reminder is role:system, continuation is role:user" do
      sid = "compose-#{System.unique_integer([:positive])}"

      reminder = OptimalSystemAgent.Agent.CompactionSafety.build_reminder_message(sid)
      continuation = ProactiveCompaction.continuation_message()

      # No active background tasks/todos/subagents for a fresh session id -> nil,
      # proving the reminder and continuation are independent, separately-gated
      # pieces rather than one replacing the other.
      assert reminder == nil
      assert continuation.role == "user"
      assert continuation.metadata.compaction_continue == true
    end
  end
end
