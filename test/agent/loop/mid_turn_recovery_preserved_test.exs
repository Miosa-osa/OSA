defmodule OptimalSystemAgent.Agent.Loop.MidTurnRecoveryPreservedTest do
  @moduledoc """
  `Loop.end_session/2` splits on one question — is a turn in flight? — and
  answers it with `turn_in_flight?/1`. The predicate tested for `status:
  :processing`, a status a real user turn never carries.

  `TurnPipeline.reset_per_turn_fields/1` stamps `:thinking` at the top of every
  turn and the turn ends back at `:idle`; `:processing` is written in exactly
  one place in the tree, the synthetic background-task `:poke` turn. So for
  every REAL turn the predicate said "no turn in flight" and `end_session/2`
  deleted the crash checkpoint and the durable step log — the two markers
  `Loop.init/1` reads back to restore an interrupted turn, and exactly the
  recovery evidence `end_session/2`'s own comment says is only safe to clear at
  a genuine idle boundary.

  What is lost: the checkpoint carries the turn's message history, iteration,
  plan_mode, turn_count and accumulated spend; the durable log carries the
  per-step record that makes completed tool calls replay-skippable. Deleting
  both means a `/clear`, a `stop_session/1`, or an application stop landing
  mid-turn discards the turn's work AND re-runs its side effects on resume.

  These tests drive the real `terminate/2` path — a started Loop, stopped for
  real — and assert on the surviving files, not on the predicate's return value.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.DurableLog

  setup do
    if is_nil(Process.whereis(OptimalSystemAgent.SessionRegistry)) do
      start_supervised!({Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry})
    end

    if is_nil(Process.whereis(OptimalSystemAgent.SessionSupervisor)) do
      start_supervised!(
        {DynamicSupervisor, name: OptimalSystemAgent.SessionSupervisor, strategy: :one_for_one}
      )
    end

    try do
      :ets.new(:osa_cancel_flags, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp checkpoint_path(session_id) do
    :optimal_system_agent
    |> Application.get_env(:checkpoint_dir, "~/.osa/checkpoints")
    |> Path.expand()
    |> Path.join("#{session_id}.json")
  end

  # Start a real Loop, park it at `status`, and lay down both recovery markers
  # the way a turn in progress would have.
  defp loop_at(status) do
    session_id = "mid-turn-#{status}-#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: session_id, channel: :test}
      )

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: status,
          messages: [
            %{role: "user", content: "write the migration"},
            %{role: "assistant", content: "starting"}
          ],
          iteration: 4,
          turn_count: 2
      }
    end)

    state = :sys.get_state(pid)
    Loop.checkpoint_state(state)
    DurableLog.record(session_id, "step-1", %{name: "file_edit"}, %{}, "ok")

    assert File.exists?(checkpoint_path(session_id)),
           "precondition: the turn left a checkpoint"

    assert DurableLog.step_count(session_id) == 1,
           "precondition: the turn left a durable step"

    on_exit(fn ->
      File.rm(checkpoint_path(session_id))
      File.rm(DurableLog.log_path(session_id))
    end)

    {session_id, pid}
  end

  describe "a clean stop landing mid-turn keeps the recovery markers" do
    # `:thinking` is what EVERY real user turn carries for its whole duration.
    # This is the case the old predicate got wrong, and it is the common one.
    test "status :thinking — the status a real user turn actually has" do
      {session_id, pid} = loop_at(:thinking)

      GenServer.stop(pid, :normal)

      assert File.exists?(checkpoint_path(session_id)),
             "a turn that had not finished must keep its crash checkpoint — " <>
               "init/1 reads it back to restore the turn"

      assert DurableLog.step_count(session_id) == 1,
             "a turn that had not finished must keep its durable step log — " <>
               "without it, completed tool calls re-run on resume"
    end

    # The one status the old predicate did recognise. It must keep working.
    test "status :processing — the synthetic background-task turn" do
      {session_id, pid} = loop_at(:processing)

      GenServer.stop(pid, :normal)

      assert File.exists?(checkpoint_path(session_id))
      assert DurableLog.step_count(session_id) == 1
    end
  end

  describe "a clean stop at an idle boundary still clears them" do
    # The predicate must not simply answer "in flight" to everything: a session
    # stopped between turns has nothing to recover, and leaving the markers
    # behind makes every later start read a stale turn back.
    test "status :idle — nothing in flight, markers are cleared" do
      {session_id, pid} = loop_at(:idle)

      GenServer.stop(pid, :normal)

      refute File.exists?(checkpoint_path(session_id)),
             "an idle boundary is the one place clearing is safe, and must stay so"

      assert DurableLog.step_count(session_id) == 0
    end
  end
end
