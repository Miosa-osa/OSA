defmodule OptimalSystemAgent.Tools.TaskLifecycleTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.TaskList.Tool, as: TaskList
  alias OptimalSystemAgent.Tools.Builtins.TaskOutput.Handler, as: TaskOutput
  alias OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool, as: TaskTranscript
  alias OptimalSystemAgent.Tools.Builtins.TaskWait.Tool, as: TaskWait
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    runs_dir =
      Path.join(System.tmp_dir!(), "osa_task_lifecycle_#{System.unique_integer([:positive])}")

    Application.put_env(:optimal_system_agent, :agent_runs_dir, runs_dir)

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :agent_runs_dir)
      File.rm_rf(runs_dir)
    end)

    %{ctx: UseContext.empty()}
  end

  test "task_output reads completed agent results from RunStore", %{ctx: ctx} do
    seed_completed_run("agent:test:output")

    assert {:ok, output} = TaskOutput.execute(%{"agent_id" => "agent:test:output"}, ctx)
    assert output =~ "Agent agent:test:output completed"
    assert output =~ "done"
  end

  test "task_list lists known runs", %{ctx: ctx} do
    seed_completed_run("agent:test:list")

    assert {:ok, output} = TaskList.execute(%{}, ctx)
    assert output =~ "agent:test:list"
    assert output =~ "[completed]"
  end

  test "task_wait returns completed result", %{ctx: ctx} do
    seed_completed_run("agent:test:wait")

    assert {:ok, output} =
             TaskWait.execute(%{"agent_id" => "agent:test:wait", "timeout_ms" => 1}, ctx)

    assert output =~ "done"
  end

  test "task_transcript reads run transcript", %{ctx: ctx} do
    seed_completed_run("agent:test:transcript")

    assert {:ok, output} = TaskTranscript.execute(%{"agent_id" => "agent:test:transcript"}, ctx)
    assert output =~ "START role=tester"
  end

  defp seed_completed_run(agent_id) do
    RunStore.start_run(%{
      agent_id: agent_id,
      parent_session_id: "test",
      role: "tester",
      task: "check lifecycle"
    })

    RunStore.complete(agent_id, %{
      agent_id: agent_id,
      parent_session_id: "test",
      role: "tester",
      status: :completed,
      summary: "done",
      files_changed: [],
      commands_run: [],
      tool_count: 0,
      tokens_used: 0,
      duration_ms: 1,
      errors: [],
      next_actions: [],
      transcript_path: "",
      worktree: nil
    })
  end
end
