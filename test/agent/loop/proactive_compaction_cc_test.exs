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
end
