defmodule OptimalSystemAgent.Events.StreamTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Events.Stream
  alias OptimalSystemAgent.Events.Event

  # Start the registry once for this test module
  setup_all do
    case Registry.start_link(keys: :unique, name: OptimalSystemAgent.EventStreamRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Each test gets a unique session_id to avoid collisions in async mode
  defp unique_session_id, do: "test-#{System.unique_integer([:positive, :monotonic])}"

  defp make_event(type \\ :tool_call, opts \\ []) do
    time = Keyword.get(opts, :time, DateTime.utc_now())
    session_id = Keyword.get(opts, :session_id, "test")

    %Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: type,
      source: "test",
      time: time,
      session_id: session_id
    }
  end

  setup do
    sid = unique_session_id()
    {:ok, pid} = Stream.start_link(sid)
    on_exit(fn -> if Process.alive?(pid), do: Stream.stop(sid) end)
    %{sid: sid, pid: pid}
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  describe "start/stop lifecycle" do
    test "start_link registers the stream", %{sid: sid} do
      [{pid, _}] = Registry.lookup(OptimalSystemAgent.EventStreamRegistry, sid)
      assert is_pid(pid)
    end

    test "stop terminates the process", %{sid: sid, pid: pid} do
      assert Process.alive?(pid)
      Stream.stop(sid)
      refute Process.alive?(pid)
    end

    test "stop on already-stopped stream is a no-op", %{sid: sid} do
      Stream.stop(sid)
      assert :ok == Stream.stop(sid)
    end

    test "duplicate start_link for same session returns error", %{sid: sid} do
      assert {:error, {:already_started, _}} = Stream.start_link(sid)
    end
  end

  # ── Append + Retrieval ─────────────────────────────────────────────

  describe "append and events retrieval" do
    test "append returns :ok and event is retrievable", %{sid: sid} do
      event = make_event()
      assert :ok = Stream.append(sid, event)
      assert {:ok, [^event]} = Stream.events(sid)
    end

    test "events returns empty list on fresh stream", %{sid: sid} do
      assert {:ok, []} = Stream.events(sid)
    end

    test "events preserves insertion order", %{sid: sid} do
      e1 = make_event(:llm_request)
      e2 = make_event(:llm_response)
      e3 = make_event(:tool_call)

      Stream.append(sid, e1)
      Stream.append(sid, e2)
      Stream.append(sid, e3)

      assert {:ok, [^e1, ^e2, ^e3]} = Stream.events(sid)
    end

    test "append to non-existent session returns error" do
      assert {:error, :not_found} = Stream.append("nonexistent-session", make_event())
    end

    test "count returns correct number of events", %{sid: sid} do
      assert {:ok, 0} = Stream.count(sid)

      Stream.append(sid, make_event())
      Stream.append(sid, make_event())
      assert {:ok, 2} = Stream.count(sid)
    end
  end

  # ── Filtering ──────────────────────────────────────────────────────

  describe "type filtering" do
    test "filters events by type", %{sid: sid} do
      e1 = make_event(:tool_call)
      e2 = make_event(:llm_response)
      e3 = make_event(:tool_call)

      Stream.append(sid, e1)
      Stream.append(sid, e2)
      Stream.append(sid, e3)

      assert {:ok, [^e1, ^e3]} = Stream.events(sid, type: :tool_call)
      assert {:ok, [^e2]} = Stream.events(sid, type: :llm_response)
    end

    test "type filter with no matches returns empty list", %{sid: sid} do
      Stream.append(sid, make_event(:tool_call))
      assert {:ok, []} = Stream.events(sid, type: :nonexistent_type)
    end
  end

  describe "since filtering" do
    test "filters events by time", %{sid: sid} do
      t1 = ~U[2026-03-01 00:00:00Z]
      t2 = ~U[2026-03-02 00:00:00Z]
      t3 = ~U[2026-03-03 00:00:00Z]
      cutoff = ~U[2026-03-02 00:00:00Z]

      e1 = make_event(:tool_call, time: t1)
      e2 = make_event(:tool_call, time: t2)
      e3 = make_event(:tool_call, time: t3)

      Stream.append(sid, e1)
      Stream.append(sid, e2)
      Stream.append(sid, e3)

      assert {:ok, [^e2, ^e3]} = Stream.events(sid, since: cutoff)
    end
  end

  describe "limit filtering" do
    test "limits number of returned events (most recent)", %{sid: sid} do
      for i <- 1..5 do
        Stream.append(
          sid,
          make_event(:tool_call, time: DateTime.add(~U[2026-03-01 00:00:00Z], i, :hour))
        )
      end

      {:ok, events} = Stream.events(sid, limit: 2)
      assert length(events) == 2
    end
  end

  describe "combined filters" do
    test "type + since + limit work together", %{sid: sid} do
      t_old = ~U[2026-03-01 00:00:00Z]
      t_new1 = ~U[2026-03-03 01:00:00Z]
      t_new2 = ~U[2026-03-03 02:00:00Z]
      t_new3 = ~U[2026-03-03 03:00:00Z]

      Stream.append(sid, make_event(:tool_call, time: t_old))
      Stream.append(sid, make_event(:llm_response, time: t_new1))
      Stream.append(sid, make_event(:tool_call, time: t_new1))
      Stream.append(sid, make_event(:tool_call, time: t_new2))
      Stream.append(sid, make_event(:tool_call, time: t_new3))

      {:ok, events} =
        Stream.events(sid, type: :tool_call, since: ~U[2026-03-02 00:00:00Z], limit: 2)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.type == :tool_call))
    end
  end

  # ── Subscribe / Unsubscribe ────────────────────────────────────────

  describe "subscribe and receive events" do
    test "subscriber receives {:event, event} messages", %{sid: sid} do
      Stream.subscribe(sid, self())
      event = make_event()
      Stream.append(sid, event)
      assert_receive {:event, ^event}, 500
    end

    test "multiple subscribers all receive events", %{sid: sid} do
      # Use a task as a second subscriber
      parent = self()

      task =
        Task.async(fn ->
          Stream.subscribe(sid, self())
          send(parent, :subscribed)
          assert_receive {:event, _event}, 1000
          :received
        end)

      # Wait for task to subscribe
      assert_receive :subscribed, 500

      Stream.subscribe(sid, self())
      event = make_event()
      Stream.append(sid, event)

      assert_receive {:event, ^event}, 500
      assert Task.await(task) == :received
    end

    test "unsubscribed process stops receiving events", %{sid: sid} do
      Stream.subscribe(sid, self())
      Stream.unsubscribe(sid, self())

      Stream.append(sid, make_event())
      refute_receive {:event, _}, 100
    end

    test "double subscribe is idempotent", %{sid: sid} do
      assert :ok = Stream.subscribe(sid, self())
      assert :ok = Stream.subscribe(sid, self())

      event = make_event()
      Stream.append(sid, event)

      # Should receive only once
      assert_receive {:event, ^event}, 500
      refute_receive {:event, _}, 100
    end

    test "unsubscribe on non-subscriber is a no-op", %{sid: sid} do
      assert :ok = Stream.unsubscribe(sid, self())
    end
  end

  # ── Subscriber auto-cleanup ────────────────────────────────────────

  describe "subscriber auto-cleanup on exit" do
    test "dead subscriber is removed and does not receive events", %{sid: sid} do
      # Spawn a process, subscribe it, then kill it
      pid =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      Stream.subscribe(sid, pid)
      send(pid, :die)

      # Give the monitor DOWN message time to propagate
      Process.sleep(50)

      # Append an event — should not crash even though subscriber is dead
      event = make_event()
      assert :ok = Stream.append(sid, event)

      # The stream should still be healthy
      assert {:ok, [^event]} = Stream.events(sid)
    end
  end

  # ── Replay ─────────────────────────────────────────────────────────

  describe "replay by time range" do
    test "returns events within [from, to] inclusive", %{sid: sid} do
      t1 = ~U[2026-03-01 00:00:00Z]
      t2 = ~U[2026-03-02 00:00:00Z]
      t3 = ~U[2026-03-03 00:00:00Z]
      t4 = ~U[2026-03-04 00:00:00Z]

      e1 = make_event(:tool_call, time: t1)
      e2 = make_event(:llm_request, time: t2)
      e3 = make_event(:llm_response, time: t3)
      e4 = make_event(:agent_response, time: t4)

      Enum.each([e1, e2, e3, e4], &Stream.append(sid, &1))

      assert {:ok, [^e2, ^e3]} = Stream.replay(sid, t2, t3)
    end

    test "replay with no matches returns empty list", %{sid: sid} do
      Stream.append(sid, make_event(:tool_call, time: ~U[2026-03-01 00:00:00Z]))
      assert {:ok, []} = Stream.replay(sid, ~U[2026-04-01 00:00:00Z], ~U[2026-04-02 00:00:00Z])
    end

    test "replay includes boundary events", %{sid: sid} do
      t = ~U[2026-03-01 12:00:00Z]
      event = make_event(:tool_call, time: t)
      Stream.append(sid, event)

      assert {:ok, [^event]} = Stream.replay(sid, t, t)
    end

    test "replay on non-existent session returns error" do
      assert {:error, :not_found} =
               Stream.replay("nope", ~U[2026-01-01 00:00:00Z], ~U[2026-12-31 00:00:00Z])
    end
  end

  # ── Circular buffer eviction ───────────────────────────────────────

  describe "circular buffer eviction" do
    test "drops oldest events when exceeding max_events", %{sid: sid, pid: pid} do
      # Override max_events to a small value for testing
      :sys.replace_state(pid, fn state -> %{state | max_events: 5} end)

      events =
        for i <- 1..8 do
          e = make_event(:tool_call, time: DateTime.add(~U[2026-03-01 00:00:00Z], i, :second))
          Stream.append(sid, e)
          e
        end

      {:ok, stored} = Stream.events(sid)
      assert length(stored) == 5

      # Should have the last 5 events (indices 3..7)
      expected = Enum.slice(events, 3..7)
      assert stored == expected
    end

    test "count never exceeds max_events", %{sid: sid, pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | max_events: 3} end)

      for _ <- 1..10 do
        Stream.append(sid, make_event())
      end

      assert {:ok, 3} = Stream.count(sid)
    end
  end

  # ── Concurrent appends ─────────────────────────────────────────────

  describe "concurrent appends" do
    test "handles many concurrent appends without data loss", %{sid: sid} do
      n = 100

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            event =
              make_event(:tool_call, time: DateTime.add(~U[2026-03-01 00:00:00Z], i, :second))

            Stream.append(sid, event)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      {:ok, count} = Stream.count(sid)
      assert count == n
    end

    test "concurrent subscribe and append do not crash", %{sid: sid} do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Stream.subscribe(sid, self())
              Process.sleep(10)
              Stream.unsubscribe(sid, self())
            else
              Stream.append(sid, make_event())
            end
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # Stream is still healthy
      assert {:ok, _} = Stream.events(sid)
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────

  describe "edge cases" do
    test "events/subscribe/unsubscribe on non-existent session" do
      assert {:error, :not_found} = Stream.events("ghost")
      assert {:error, :not_found} = Stream.subscribe("ghost")
      assert {:error, :not_found} = Stream.unsubscribe("ghost")
      assert {:error, :not_found} = Stream.count("ghost")
    end

    test "append event without time field still works", %{sid: sid} do
      event = %{id: "bare-1", type: :test, source: "test"}
      assert :ok = Stream.append(sid, event)
      {:ok, [^event]} = Stream.events(sid)
    end
  end
end
