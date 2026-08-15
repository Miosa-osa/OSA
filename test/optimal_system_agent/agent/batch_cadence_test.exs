defmodule OptimalSystemAgent.Agent.BatchCadenceTest do
  @moduledoc """
  The batching nudge (measured item B).

  The load-bearing half of these tests is the same as for redundant-read
  suppression: not "does it fire" but **"does it shut up"**. A reminder that
  fires every turn is noise the model learns to ignore, and OSA has already run
  that experiment by accident — the stall detector fired 247 times with no
  observable effect. Every bound below is what stops this becoming the 248th.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.BatchCadence

  setup do
    BatchCadence.reset()
    {:ok, sid: "cadence-#{System.unique_integer([:positive])}"}
  end

  defp flatten(sid, n), do: Enum.each(1..n, fn _ -> BatchCadence.record(sid, 1) end)

  describe "when it fires" do
    test "after a run of single-call turns, past the early-session floor", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      assert BatchCadence.nudge?(sid, BatchCadence.min_turn())
    end

    test "the message names independent work, not a target number", %{sid: sid} do
      msg = BatchCadence.message()

      assert msg =~ "independent"
      assert msg =~ "one turn"

      # Steering at opencode's 1.91 calls/turn would be steering at an artefact:
      # its prompt forbids compound shell commands, which inflates its call
      # count without doing more work.
      refute msg =~ "1.91"

      # And it must not re-litigate safety — ConflictScope decides that centrally.
      assert msg =~ "serialised for you"
      assert String.length(msg) < 500, "a long reminder is a cost paid every time it fires"

      # Silences the unused-variable style warning while asserting nothing about
      # session state, which this test does not touch.
      assert is_binary(sid)
    end
  end

  describe "when it stays quiet" do
    test "before the window is full", %{sid: sid} do
      flatten(sid, BatchCadence.window() - 1)
      refute BatchCadence.nudge?(sid, BatchCadence.min_turn())
    end

    test "in the early turns, where batching is already at 0.34", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      refute BatchCadence.nudge?(sid, BatchCadence.min_turn() - 1)
    end

    test "when even one recent turn batched", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      BatchCadence.record(sid, 3)
      flatten(sid, BatchCadence.window() - 1)

      refute BatchCadence.nudge?(sid, 40),
             "a batch inside the window means the pattern has not flattened"
    end

    test "during the cooldown after a firing", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      turn = BatchCadence.min_turn()
      assert BatchCadence.nudge?(sid, turn)

      for t <- (turn + 1)..(turn + BatchCadence.cooldown_for(1) - 1) do
        flatten(sid, 1)
        refute BatchCadence.nudge?(sid, t), "fired again #{t - turn} turns after the last one"
      end
    end

    test "the gap doubles, so it can never become background noise", %{sid: sid} do
      # A flat cooldown spent every firing inside the first ~30 turns, which is
      # the opposite of what the decay curve asks for: the collapse is worst at
      # turn 60+. Doubling covers both ends of the session-length distribution.
      turns =
        Enum.reduce(0..400, {[], nil}, fn t, {fired, _last} ->
          flatten(sid, 1)
          if BatchCadence.nudge?(sid, t), do: {[t | fired], t}, else: {fired, nil}
        end)
        |> elem(0)
        |> Enum.reverse()

      assert length(turns) == BatchCadence.max_fires()

      gaps = turns |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      assert gaps == Enum.sort(gaps), "the interval between nudges must never shrink"
      assert List.last(turns) > 100, "a long session must still be reached late on"
    end

    test "for good, after the per-session cap", %{sid: sid} do
      fired =
        Enum.count(0..2_000//1, fn t ->
          flatten(sid, 1)
          BatchCadence.nudge?(sid, t)
        end)

      assert fired == BatchCadence.max_fires(),
             "a reminder that keeps coming is not information"
    end

    test "a true answer is consumed — two callers cannot both nudge", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      turn = BatchCadence.min_turn()

      assert BatchCadence.nudge?(sid, turn)
      refute BatchCadence.nudge?(sid, turn)
    end
  end

  describe "isolation and safety" do
    test "cadence is per-session", %{sid: sid} do
      flatten(sid, BatchCadence.window())
      other = "other-#{System.unique_integer([:positive])}"

      assert BatchCadence.nudge?(sid, 40)
      refute BatchCadence.nudge?(other, 40)
    end

    test "a nil session id is tracked rather than crashing" do
      Enum.each(1..BatchCadence.window(), fn _ -> BatchCadence.record(nil, 1) end)
      assert is_boolean(BatchCadence.nudge?(nil, 40))
    end

    test "garbage never raises", %{sid: sid} do
      assert :ok == BatchCadence.record(sid, :not_a_number)
      assert :ok == BatchCadence.record(sid, -1)
      refute BatchCadence.nudge?(sid, :not_a_turn)
    end

    test "history is bounded — a 230-turn session does not grow without limit", %{sid: sid} do
      flatten(sid, 500)
      assert BatchCadence.nudge?(sid, 40)
    end
  end
end
