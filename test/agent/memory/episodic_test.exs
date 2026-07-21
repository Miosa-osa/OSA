defmodule OptimalSystemAgent.Agent.Memory.EpisodicTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Memory.Episodic

  @table :osa_episodic_memory

  setup do
    # Start the Episodic GenServer if not running
    case Process.whereis(Episodic) do
      nil ->
        {:ok, pid} = Episodic.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      pid ->
        # `record/3` is an async GenServer cast, so an earlier test's write can
        # still be sitting in the mailbox here. Drain it FIRST (a synchronous
        # :sys.get_state is processed in-order, after every queued cast) so those
        # writes land BEFORE we wipe — otherwise a stray cast lands AFTER
        # delete_all_objects and inflates the global counts stats/0 reports.
        try do
          :sys.get_state(pid)
          :ets.delete_all_objects(@table)
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end

        on_exit(fn -> if Process.alive?(pid), do: :ets.delete_all_objects(@table) end)
    end

    :ok
  end

  # ── record/3 and recent/2 ──────────────────────────────────────────

  describe "record/3 and recent/2" do
    test "records an event and retrieves it" do
      Episodic.record(:tool_call, %{tool: "file_read", path: "/foo.ex"}, "sess-1")

      # Allow async cast to process
      :timer.sleep(50)

      events = Episodic.recent("sess-1")
      assert length(events) == 1

      event = hd(events)
      assert event.event_type == :tool_call
      assert event.data == %{tool: "file_read", path: "/foo.ex"}
      assert event.session_id == "sess-1"
      assert %DateTime{} = event.timestamp
    end

    test "returns events in reverse chronological order" do
      Episodic.record(:user_message, %{content: "first"}, "sess-1")
      :timer.sleep(10)
      Episodic.record(:user_message, %{content: "second"}, "sess-1")
      :timer.sleep(10)
      Episodic.record(:user_message, %{content: "third"}, "sess-1")
      :timer.sleep(50)

      events = Episodic.recent("sess-1", 10)
      assert length(events) == 3
      contents = Enum.map(events, fn e -> e.data.content end)
      assert contents == ["third", "second", "first"]
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        Episodic.record(:tool_call, %{index: i}, "sess-1")
      end

      :timer.sleep(50)

      events = Episodic.recent("sess-1", 2)
      assert length(events) == 2
    end

    test "separates events by session" do
      Episodic.record(:tool_call, %{tool: "a"}, "sess-1")
      Episodic.record(:tool_call, %{tool: "b"}, "sess-2")
      :timer.sleep(50)

      assert length(Episodic.recent("sess-1")) == 1
      assert length(Episodic.recent("sess-2")) == 1
      assert length(Episodic.recent("sess-3")) == 0
    end
  end

  # ── recall/2 ────────────────────────────────────────────────────────

  describe "recall/2" do
    test "finds events matching keyword query" do
      Episodic.record(:error, %{message: "connection timeout on database"}, "sess-1")
      Episodic.record(:tool_call, %{tool: "file_read"}, "sess-1")
      :timer.sleep(50)

      results = Episodic.recall("timeout database")
      assert length(results) >= 1

      # The error event should match
      error_event = Enum.find(results, &(&1.event_type == :error))
      assert error_event != nil
      assert error_event.relevance > 0.0
    end

    test "returns results sorted by relevance" do
      Episodic.record(:error, %{message: "timeout error"}, "sess-1")
      Episodic.record(:error, %{message: "timeout connection pool exhaustion timeout"}, "sess-1")
      :timer.sleep(50)

      results = Episodic.recall("timeout")
      assert length(results) >= 1

      # Results should be sorted descending by relevance
      relevances = Enum.map(results, & &1.relevance)
      assert relevances == Enum.sort(relevances, :desc)
    end

    test "filters by session_id" do
      Episodic.record(:error, %{message: "timeout"}, "sess-1")
      Episodic.record(:error, %{message: "timeout"}, "sess-2")
      :timer.sleep(50)

      results = Episodic.recall("timeout", session_id: "sess-1")
      assert Enum.all?(results, &(&1.session_id == "sess-1"))
    end

    test "filters by event_type" do
      Episodic.record(:error, %{message: "something broke"}, "sess-1")
      Episodic.record(:tool_call, %{tool: "something"}, "sess-1")
      :timer.sleep(50)

      results = Episodic.recall("something", event_type: :error)
      assert Enum.all?(results, &(&1.event_type == :error))
    end

    test "respects limit" do
      for i <- 1..10 do
        Episodic.record(:tool_call, %{tool: "tool_#{i}"}, "sess-1")
      end

      :timer.sleep(50)

      results = Episodic.recall("tool", limit: 3)
      assert length(results) <= 3
    end
  end

  # ── temporal_decay/2 ────────────────────────────────────────────────

  describe "temporal_decay/2" do
    test "returns 1.0 for current timestamp" do
      now = DateTime.utc_now()
      score = Episodic.temporal_decay(now, 1.0)
      assert_in_delta score, 1.0, 0.05
    end

    test "returns ~0.5 for event at half-life age" do
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      score = Episodic.temporal_decay(one_hour_ago, 1.0)
      assert_in_delta score, 0.5, 0.05
    end

    test "returns ~0.25 for event at 2x half-life age" do
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)
      score = Episodic.temporal_decay(two_hours_ago, 1.0)
      assert_in_delta score, 0.25, 0.05
    end

    test "older events have lower scores" do
      recent = DateTime.add(DateTime.utc_now(), -600, :second)
      old = DateTime.add(DateTime.utc_now(), -36_000, :second)

      recent_score = Episodic.temporal_decay(recent, 1.0)
      old_score = Episodic.temporal_decay(old, 1.0)

      assert recent_score > old_score
    end

    test "longer half-life means slower decay" do
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      short_decay = Episodic.temporal_decay(one_hour_ago, 0.5)
      long_decay = Episodic.temporal_decay(one_hour_ago, 4.0)

      assert long_decay > short_decay
    end
  end

  # ── stats/0 ─────────────────────────────────────────────────────────

  describe "stats/0" do
    test "returns accurate counts" do
      Episodic.record(:tool_call, %{tool: "a"}, "sess-1")
      Episodic.record(:error, %{msg: "b"}, "sess-1")
      Episodic.record(:tool_call, %{tool: "c"}, "sess-2")
      # Flush these three casts deterministically (drain the mailbox) instead of
      # racing a fixed sleep — stats/0 reads ETS directly and counts globally.
      :sys.get_state(Episodic)

      stats = Episodic.stats()
      assert stats.total_events == 3
      assert stats.sessions["sess-1"] == 2
      assert stats.sessions["sess-2"] == 1
      assert stats.event_types[:tool_call] == 2
      assert stats.event_types[:error] == 1
    end
  end

  # ── clear_session/1 ─────────────────────────────────────────────────

  describe "clear_session/1" do
    test "removes all events for a session" do
      Episodic.record(:tool_call, %{tool: "a"}, "sess-1")
      Episodic.record(:tool_call, %{tool: "b"}, "sess-2")
      :timer.sleep(50)

      Episodic.clear_session("sess-1")
      :timer.sleep(50)

      assert length(Episodic.recent("sess-1")) == 0
      assert length(Episodic.recent("sess-2")) == 1
    end
  end

  # ── recent/2 relevance decay ────────────────────────────────────────

  describe "recent/2 relevance" do
    test "recent events have relevance close to 1.0" do
      Episodic.record(:tool_call, %{tool: "fresh"}, "sess-1")
      :timer.sleep(50)

      events = Episodic.recent("sess-1")
      assert length(events) == 1
      # Just-recorded event should have high relevance
      assert hd(events).relevance > 0.9
    end
  end
end
