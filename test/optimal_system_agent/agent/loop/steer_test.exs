defmodule OptimalSystemAgent.Agent.Loop.SteerTest do
  @moduledoc """
  Mid-turn steer tests (primitive #32).

  Exercises the ETS steer queue (`Loop.Steer`) that transports a user directive
  into a RUNNING turn, plus the two injection paths that consume it:

    * the running ReactLoop drains it between steps (unit-tested here via the
      same `drain/1` + `to_messages/1` the loop uses at each step boundary), and
    * the idle-path `Loop.handle_cast({:steer, _}, state)` folds any still-queued
      steers into history.

  The `:osa_steer_queue` ETS table is created at application start, so these
  tests run against the real table with per-test unique session ids for
  isolation.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.Steer

  setup do
    session_id = "steer-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Steer.drain(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "Steer queue" do
    test "queue/drain round-trips in FIFO order and empties the queue", %{session_id: sid} do
      assert Steer.count(sid) == 0

      :ok = Steer.queue(sid, "first")
      :ok = Steer.queue(sid, "second")
      :ok = Steer.queue(sid, "third")

      assert Steer.count(sid) == 3

      assert Steer.drain(sid) == ["first", "second", "third"]

      # Drain is destructive — the queue is now empty.
      assert Steer.count(sid) == 0
      assert Steer.drain(sid) == []
    end

    test "drain is isolated per session", %{session_id: sid} do
      other = "steer-test-other-#{System.unique_integer([:positive])}"
      on_exit(fn -> Steer.drain(other) end)

      :ok = Steer.queue(sid, "mine")
      :ok = Steer.queue(other, "theirs")

      assert Steer.drain(sid) == ["mine"]
      # The other session's steer is untouched.
      assert Steer.count(other) == 1
      assert Steer.drain(other) == ["theirs"]
    end

    test "to_messages/1 renders each steer as a labelled system directive" do
      [msg] = Steer.to_messages(["do X instead"])

      assert msg.role == "system"
      assert msg.content =~ "User steer"
      assert msg.content =~ "do X instead"
    end
  end

  describe "Loop mid-turn injection mechanism" do
    test "drain + to_messages produces exactly what the loop appends to history",
         %{session_id: sid} do
      :ok = Steer.queue(sid, "focus on the auth module")

      # This is precisely what ReactLoop.inject_pending_steer/1 does at each
      # step boundary: drain the queue and turn it into system messages.
      messages = sid |> Steer.drain() |> Steer.to_messages()

      assert [%{role: "system", content: content}] = messages
      assert content =~ "focus on the auth module"
    end
  end

  describe "Loop idle-path cast" do
    test "handle_cast/2 drains queued steers into message history", %{session_id: sid} do
      :ok = Steer.queue(sid, "steer A")
      :ok = Steer.queue(sid, "steer B")

      state = %Loop{session_id: sid, messages: [%{role: "user", content: "original"}]}

      {:noreply, new_state} = Loop.handle_cast({:steer, "steer B"}, state)

      # Original message preserved; two steer directives appended in order.
      assert length(new_state.messages) == 3
      assert Enum.at(new_state.messages, 0).content == "original"
      assert Enum.at(new_state.messages, 1).content =~ "steer A"
      assert Enum.at(new_state.messages, 2).content =~ "steer B"

      # Queue was consumed — no double injection on a later drain.
      assert Steer.count(sid) == 0
    end

    test "handle_cast/2 is a no-op when nothing is queued (mid-turn case already drained)",
         %{session_id: sid} do
      state = %Loop{session_id: sid, messages: [%{role: "user", content: "original"}]}

      {:noreply, new_state} = Loop.handle_cast({:steer, "already drained"}, state)

      assert new_state.messages == state.messages
    end
  end

  describe "Loop.steer/2 public API" do
    test "queues a steer even when no live loop exists, returning :ok", %{session_id: sid} do
      # No registered session process — steer/2 must not raise; the ETS queue
      # holds the directive until a turn drains it.
      assert :ok = Loop.steer(sid, "adapt now")
      assert "adapt now" in Steer.drain(sid)
    end
  end
end
