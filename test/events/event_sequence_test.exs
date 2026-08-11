defmodule OptimalSystemAgent.Events.EventSequenceTest do
  @moduledoc """
  Emission ordering.

  Two events emitted in a known order must stay recoverable in that order.
  Wall-clock `time` cannot do that job: it used to be stamped inside the task
  `Bus.emit/3` spawned, so the later emit could be stamped (and appended)
  first. `seq` is stamped on the caller's process, before any task is spawned.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Events.Event

  describe "Event.new/4 sequencing" do
    test "assigns a strictly increasing seq to every event" do
      seqs = for _ <- 1..500, do: Event.new(:system_event, "test", %{}).seq

      assert Enum.all?(seqs, &is_integer/1)
      assert length(Enum.uniq(seqs)) == 500
      assert seqs == Enum.sort(seqs)
    end

    test "seq increases across processes, not just within one" do
      first = Event.new(:system_event, "test", %{})

      middle =
        Task.async(fn -> Event.new(:system_event, "test", %{}) end)
        |> Task.await()

      last = Event.new(:system_event, "test", %{})

      assert first.seq < middle.seq
      assert middle.seq < last.seq
    end

    test "an explicit :seq is honoured" do
      assert Event.new(:system_event, "test", %{}, seq: 42).seq == 42
    end

    test "seq survives to_map/1 and to_cloud_event/1" do
      event = Event.new(:tool_call, "test", %{})

      assert Event.to_map(event).seq == event.seq
      assert Event.to_cloud_event(event)["seq"] == event.seq
    end
  end

  describe "Event.sort/1" do
    test "restores emission order when the wall clock disagrees" do
      # Emission order a, b, c — but the clock ran backwards between them
      # (task-scheduling order under the old code, or NTP correction).
      a = Event.new(:system_event, "test", %{n: 1}, time: ~U[2026-01-01 00:00:02Z])
      b = Event.new(:system_event, "test", %{n: 2}, time: ~U[2026-01-01 00:00:01Z])
      c = Event.new(:system_event, "test", %{n: 3}, time: ~U[2026-01-01 00:00:03Z])

      assert Enum.map(Event.sort([c, b, a]), & &1.data.n) == [1, 2, 3]
    end

    test "orders unsequenced events by time and keeps them ahead of sequenced ones" do
      legacy_old = %{type: :system_event, time: ~U[2026-01-01 00:00:01Z], data: %{n: :old}}
      legacy_new = %{type: :system_event, time: ~U[2026-01-01 00:00:09Z], data: %{n: :new}}
      sequenced = Event.new(:system_event, "test", %{n: :seq})

      sorted = Event.sort([sequenced, legacy_new, legacy_old])
      assert Enum.map(sorted, & &1.data.n) == [:old, :new, :seq]
    end
  end

  describe "Bus.emit/3 stamping" do
    test "returns the built event with a seq and a timestamp" do
      {:ok, event} = Bus.emit(:system_event, %{probe: true}, source: "seq-test")

      assert %Event{} = event
      assert is_integer(event.seq)
      assert %DateTime{} = event.time
      assert event.type == :system_event
      assert event.data == %{probe: true}
    end

    test "stamps seq on the caller's process, before the emit task runs" do
      # If the Event were built inside the spawned task (the defect), its seq
      # would be drawn after this call returned — i.e. after `after_call`.
      before_call = Event.next_seq()
      {:ok, event} = Bus.emit(:system_event, %{}, source: "seq-test")
      after_call = Event.next_seq()

      assert before_call < event.seq
      assert event.seq < after_call
    end

    test "events emitted in a known order carry increasing seq in that order" do
      events =
        for n <- 1..200 do
          {:ok, event} = Bus.emit(:system_event, %{n: n}, source: "seq-test")
          event
        end

      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert length(Enum.uniq(seqs)) == 200

      # And sorting a shuffled delivery order restores the emission order.
      restored = events |> Enum.shuffle() |> Event.sort() |> Enum.map(& &1.data.n)
      assert restored == Enum.to_list(1..200)
    end
  end
end
