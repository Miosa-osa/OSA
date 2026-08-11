defmodule OptimalSystemAgent.Agent.CompactionEventsTest do
  @moduledoc """
  Compaction must be VISIBLE in the TUI.

  The regression these tests lock down: compaction announced itself on
  `Events.Bus` only (`Loop.ProactiveCompaction.emit_event/4`), and the Bus is a
  transport the TUI does not consume. The SSE stream the Rust TUI connects to
  subscribes to `Phoenix.PubSub` topic `"osa:session:<id>"` and nothing else, so
  a multi-minute compaction froze the turn with no explanation on screen.

  Every assertion here is therefore made against the PubSub topic specifically.
  Asserting on the Bus would pass on the broken code.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.CompactionEvents

  setup do
    sid = "compaction-events-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    {:ok, sid: sid}
  end

  describe "reaching the transport the TUI actually consumes" do
    test "started/3 broadcasts on the session PubSub topic", %{sid: sid} do
      CompactionEvents.started(sid, :manual, 84_000)

      assert_receive {:osa_event, event}, 1_000

      # The SSE loop unwraps `%{type: :system_event, event: sub}` and uses `sub`
      # as the wire event name, so both keys must be present and exact.
      assert event.type == :system_event
      assert event.event == :compaction_started
      assert event.session_id == sid
      assert event.trigger == "manual"
      assert event.tokens_before == 84_000
    end

    test "completed/2 carries real before/after numbers", %{sid: sid} do
      CompactionEvents.completed(sid,
        tokens_before: 84_000,
        tokens_after: 21_000,
        messages_before: 52,
        messages_after: 14,
        duration_ms: 134_000
      )

      assert_receive {:osa_event, event}, 1_000
      assert event.event == :compaction_completed
      assert event.tokens_before == 84_000
      assert event.tokens_after == 21_000
      # 52 -> 14 means 38 messages were folded; the TUI derives the folded count
      # from these two rather than being handed a third, separately-computed
      # number that could disagree with them.
      assert event.messages_before - event.messages_after == 38
      assert event.duration_ms == 134_000
    end

    test "failed/3 reports the failure instead of letting the indicator vanish", %{sid: sid} do
      CompactionEvents.failed(sid, :summarizer_timeout, 90_000)

      assert_receive {:osa_event, event}, 1_000
      assert event.event == :compaction_failed
      assert event.reason == "summarizer timeout"
      assert event.duration_ms == 90_000
    end
  end

  describe "progress is measured, never decorative" do
    test "progress/3 reports a real 1-based chunk ratio", %{sid: sid} do
      CompactionEvents.progress(sid, 3, 8)

      assert_receive {:osa_event, event}, 1_000
      assert event.event == :compaction_progress
      assert event.chunk_index == 3
      assert event.chunk_total == 8
    end

    test "progress/3 never reports an index past the total", %{sid: sid} do
      # A bar that renders >100% is a visible lie about measured work.
      CompactionEvents.progress(sid, 12, 8)

      assert_receive {:osa_event, event}, 1_000
      assert event.chunk_index == 8
    end

    test "progress/3 emits nothing when the total is not a real count", %{sid: sid} do
      CompactionEvents.progress(sid, 1, 0)
      CompactionEvents.progress(sid, 1, nil)

      refute_receive {:osa_event, %{event: :compaction_progress}}, 200
    end
  end

  describe "degenerate sessions" do
    test "a nil session id broadcasts nothing rather than crashing", %{sid: sid} do
      # No session id means no topic to broadcast on. It must stay silent on
      # THIS session's topic — never leak one session's compaction into another.
      CompactionEvents.started(nil, :auto, 1_000)
      CompactionEvents.started("", :auto, 1_000)

      refute_receive {:osa_event, _}, 200
      assert CompactionEvents.current_session_id() == nil

      Process.put(:osa_compact_session_id, sid)
      assert CompactionEvents.current_session_id() == sid
    after
      Process.delete(:osa_compact_session_id)
    end
  end
end
