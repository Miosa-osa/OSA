defmodule OptimalSystemAgent.Agent.Loop.StopAllWorkTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Agent.{Loop, RunStore}
  alias OptimalSystemAgent.Shell.BackgroundManager
  @cancel_table :osa_cancel_flags

  setup do
    unless :ets.whereis(@cancel_table) != :undefined do
      :ets.new(@cancel_table, [:named_table, :public])
    end

    root = "stop-all-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    child = "agent:#{root}:background"
    grandchild = "agent:#{child}:attached"
    unrelated = "unrelated-#{root}"

    for {id, parent, background} <- [
          {child, root, true},
          {grandchild, child, false},
          {unrelated, "another-root", true}
        ] do
      RunStore.start_run(%{
        agent_id: id,
        parent_session_id: parent,
        role: "agent",
        task: "fixture",
        background: background
      })
    end

    on_exit(fn ->
      for id <- [root, child, grandchild, unrelated] do
        :ets.delete(@cancel_table, id)
        :ets.delete(@cancel_table, {:all_work_stopped, id})
        :ets.delete(@cancel_table, {:all_work_epoch, id})
      end
    end)

    {:ok, root: root, child: child, grandchild: grandchild, unrelated: unrelated}
  end

  test "STOP EVERYTHING cancels detached descendants but leaves unrelated work alone", ids do
    assert :ok = Loop.steer(ids.root, "STOP EVERYTHING")

    for id <- [ids.root, ids.child, ids.grandchild] do
      assert [{^id, true}] = :ets.lookup(@cancel_table, id)
    end

    assert :ets.lookup(@cancel_table, ids.unrelated) == []
    assert Loop.Steer.count(ids.root) == 0
  end

  test "STOP ALL WORK terminates a background descendant's real shell job", ids do
    {:ok, job} = BackgroundManager.start("sleep 30", System.tmp_dir!(), session_id: ids.child)
    on_exit(fn -> BackgroundManager.cancel_for_sessions([ids.child]) end)
    assert {:ok, %{status: :running}} = BackgroundManager.output(job)
    assert :ok = Loop.steer(ids.root, "Please STOP ALL WORK now!")
    assert {:ok, %{status: status}} = BackgroundManager.output(job)
    assert status == :killed
  end

  defmodule RecordingExecutor do
    def execute_tool_call(tc, state) do
      send(state.test_pid, :tool_executed_after_stop)
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "ran"}, "ran"}
    end
  end

  test "no pending tool starts after an all-work stop has been accepted", ids do
    assert :ok = Loop.steer(ids.root, "STOP ALL AGENTS")
    supervisor = start_supervised!(Task.Supervisor)

    for session <- [ids.root, ids.child, ids.grandchild] do
      [{_, {_, result}}] =
        Loop.ToolOrchestrator.dispatch(
          [%{id: "next", name: "recording"}],
          %{session_id: session, test_pid: self()},
          executor: RecordingExecutor,
          supervisor: supervisor
        )

      assert result == "Error: Interrupted by user"
    end

    refute_received :tool_executed_after_stop
  end

  test "all-work fence survives interrupt cleanup and covers a late registered descendant", ids do
    alias OptimalSystemAgent.Agent.Cancellation
    assert :ok = Loop.steer(ids.root, "STOP EVERYTHING")
    Loop.clear_cancel(ids.root)
    assert Cancellation.all_work_stopped?(ids.root)
    late = "late-#{ids.root}"

    RunStore.start_run(%{
      agent_id: late,
      parent_session_id: ids.child,
      role: "agent",
      task: "late",
      background: true
    })

    assert Cancellation.all_work_stopped?(late)
    assert Cancellation.cancelled?(late)
    # No live Loop exists for this late child. Returning cancelled, rather
    # than crashing with noproc, proves the execution boundary did not run it.
    assert Loop.process_message(late, "launch work") == {:error, :cancelled}
    assert Cancellation.all_work_stopped?(ids.root)
    refute Cancellation.all_work_stopped?(ids.unrelated)
    Loop.resume_all_work(ids.root)
    refute Cancellation.all_work_stopped?(late)
    Loop.clear_cancel(ids.root)
    assert :ets.lookup(@cancel_table, ids.root) == []
  end

  test "a directly submitted STOP ALL WORK never starts a model turn", ids do
    # No live root Loop exists: the stop must be handled before GenServer.call.
    assert {:ok, _} = Loop.process_message(ids.root, "STOP ALL WORK")
    assert OptimalSystemAgent.Agent.Cancellation.all_work_stopped?(ids.child)
    assert [{id, true}] = :ets.lookup(@cancel_table, ids.root)
    assert id == ids.root
  end

  test "a new user turn cannot revive a ticket captured before STOP", ids do
    alias OptimalSystemAgent.Agent.Cancellation
    old_ticket = Cancellation.all_work_ticket(ids.grandchild)
    assert Cancellation.all_work_ticket_valid?(old_ticket)
    Loop.steer(ids.root, "STOP EVERYTHING")
    Loop.resume_all_work(ids.root)
    refute Cancellation.all_work_stopped?(ids.grandchild)
    refute Cancellation.all_work_ticket_valid?(old_ticket)

    assert Loop.process_message(ids.grandchild, "old queued task", stop_ticket: old_ticket) ==
             {:error, :cancelled}

    new_ticket = Cancellation.all_work_ticket(ids.grandchild)
    assert Cancellation.all_work_ticket_valid?(new_ticket)
    Loop.cancel(ids.root)
    assert Cancellation.all_work_ticket_valid?(new_ticket)
  end

  test "plain cancel retains detached work", ids do
    assert :ok = Loop.cancel(ids.root)
    assert :ets.lookup(@cancel_table, ids.child) == []
    assert :ets.lookup(@cancel_table, ids.grandchild) == []
  end

  test "pure all-work commands are recognized without matching quotes or follow-on instructions" do
    for text <- [
          "STOP ALL WORK",
          "stop all agents please",
          "stop all tasks",
          "stop everything",
          "STOP!"
        ] do
      assert Loop.stop_intent?(text), text
    end

    for text <- [
          "Explain STOP EVERYTHING",
          "\"STOP EVERYTHING\"",
          "stop all work and deploy",
          "stop using local models",
          "stop all work on marketing",
          "do not stop all work",
          "stop the agent named everything"
        ] do
      refute Loop.stop_intent?(text), text
    end
  end
end
