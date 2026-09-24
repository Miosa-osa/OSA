defmodule OptimalSystemAgent.Learning.DoubleLoopTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Learning.DoubleLoop` — turning a
  session's buffered pain events into durable, de-duplicated lessons.

  async: false — touches the shared `Memory.Store` singleton and the shared
  `PainSink` ETS table.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Learning.{DoubleLoop, PainSink}
  alias OptimalSystemAgent.Memory

  setup do
    session_id = "double-loop-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> PainSink.clear(session_id) end)
    {:ok, session_id: session_id}
  end

  defp cleanup_lesson(text) do
    case Memory.recall(text, category: :lesson, limit: 5) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(&1.content == text))
        |> Enum.each(&Memory.delete(&1.id))

      _ ->
        :ok
    end
  end

  describe "bucket/1" do
    test "groups buffered events by kind" do
      PainSink.record("irrelevant", :repeated_probe, "a")

      events = [
        OptimalSystemAgent.Learning.PainEvent.new(:repeated_probe, "s", "a"),
        OptimalSystemAgent.Learning.PainEvent.new(:repeated_probe, "s", "b"),
        OptimalSystemAgent.Learning.PainEvent.new(:command_fix, "s", "c")
      ]

      bucketed = DoubleLoop.bucket(events) |> Map.new()
      assert length(bucketed[:repeated_probe]) == 2
      assert length(bucketed[:command_fix]) == 1
    end
  end

  describe "flush/2" do
    test "writes one lesson per pain kind and clears the buffer", %{session_id: sid} do
      PainSink.record(sid, :command_fix, "retried and succeeded")
      PainSink.record(sid, :command_fix, "retried again")
      PainSink.record(sid, :repeated_probe, "same call thrice")

      assert {:ok, lessons} = DoubleLoop.flush(sid)
      assert length(lessons) == 2

      for text <- lessons, do: on_exit(fn -> cleanup_lesson(text) end)

      assert Enum.any?(lessons, &(&1 =~ "retry"))
      assert PainSink.events(sid) == []
    end

    test "an empty buffer produces no lessons and is a no-op", %{session_id: sid} do
      assert {:ok, []} = DoubleLoop.flush(sid)
    end

    test "a saved lesson is retrievable via Memory with lesson category", %{session_id: sid} do
      PainSink.record(sid, :user_correction, "corrected once")

      assert {:ok, [text]} = DoubleLoop.flush(sid)
      on_exit(fn -> cleanup_lesson(text) end)

      assert {:ok, entries} = Memory.recall(text, category: :lesson, limit: 5)
      assert Enum.any?(entries, &(&1.content == text and &1.session_id == sid))
    end

    test "min_occurrences filters out kinds below the threshold", %{session_id: sid} do
      PainSink.record(sid, :slow_search, "slow once")

      assert {:ok, []} = DoubleLoop.flush(sid, min_occurrences: 2)
      # the buffer is only cleared on an actual flush attempt — confirm the
      # event is gone either way so a repeated flush cannot double count it.
      assert PainSink.events(sid) == []
    end

    test "an unknown/missing session id degrades to an empty result" do
      assert {:ok, []} = DoubleLoop.flush("session-that-never-recorded-anything")
    end
  end

  describe "list_lessons/1 and prune_lesson/1" do
    test "a flushed lesson appears in list_lessons and can be pruned", %{session_id: sid} do
      PainSink.record(sid, :wrong_checkout, "switched branch")
      assert {:ok, [text]} = DoubleLoop.flush(sid)

      assert {:ok, entries} = DoubleLoop.list_lessons()
      assert Enum.any?(entries, &(&1.content == text))

      entry = Enum.find(entries, &(&1.content == text))
      assert :ok = DoubleLoop.prune_lesson(entry.id)

      assert {:ok, entries_after} = DoubleLoop.list_lessons()
      refute Enum.any?(entries_after, &(&1.id == entry.id))
    end
  end
end
