defmodule OptimalSystemAgent.Agent.RunStoreTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore

  setup do
    runs_dir = Path.join(System.tmp_dir!(), "osa_run_store_#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_system_agent, :agent_runs_dir, runs_dir)

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :agent_runs_dir)
      File.rm_rf(runs_dir)
    end)

    %{runs_dir: runs_dir}
  end

  test "records lifecycle status and transcript", %{runs_dir: runs_dir} do
    agent_id = "agent:test:1"

    RunStore.start_run(%{
      agent_id: agent_id,
      parent_session_id: "test",
      role: "verifier",
      task: "verify the result"
    })

    RunStore.progress(agent_id, "file_read README.md", 1)

    RunStore.complete(agent_id, %{
      agent_id: agent_id,
      parent_session_id: "test",
      role: "verifier",
      status: :completed,
      summary: "VERDICT: PASS",
      files_changed: [],
      commands_run: [],
      tool_count: 1,
      tokens_used: 500,
      duration_ms: 12,
      errors: [],
      next_actions: [],
      transcript_path: Path.join(runs_dir, "agent_test_1.md"),
      worktree: nil
    })

    assert %{status: :completed, result: %{summary: "VERDICT: PASS"}} = RunStore.get(agent_id)
    assert Enum.any?(RunStore.list(status: :completed), &(&1.agent_id == agent_id))
    assert {:ok, transcript} = RunStore.transcript(agent_id)
    assert transcript =~ "START role=verifier"
    assert transcript =~ "PROGRESS tools=1"
    assert transcript =~ "STOP status=completed"
  end
end
