defmodule OptimalSystemAgent.Agent.ExecutionControlTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.ExecutionControl

  setup do
    dir =
      Path.join(System.tmp_dir!(), "osa-execution-control-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous do
        Application.put_env(:optimal_system_agent, :agent_runs_dir, previous)
      else
        Application.delete_env(:optimal_system_agent, :agent_runs_dir)
      end
    end)

    :ok
  end

  test "a run keeps its routing rationale, active work, metrics, and delivery state on disk" do
    assert :ok =
             ExecutionControl.start("agent:parent:explorer", %{
               parent_session_id: "parent",
               task: "Diagnose the resize regression",
               role: "explorer",
               provider: "openrouter",
               model: "anthropic/claude-sonnet-5",
               model_reason: "requires tools and a large context window",
               skill_reason: "diagnose matched the reported regression"
             })

    assert :ok =
             ExecutionControl.progress("agent:parent:explorer", %{
               current_tool: "file_grep",
               active_skills: ["diagnose"],
               tokens_used: 1_200,
               tool_count: 3,
               retry_count: 1
             })

    assert :ok =
             ExecutionControl.delivery("agent:parent:explorer", "receipt-1", :acknowledged)

    snapshot = ExecutionControl.get("agent:parent:explorer")

    assert snapshot.model_reason =~ "requires tools"
    assert snapshot.skill_reason =~ "diagnose"
    assert snapshot.active_skills == ["diagnose"]
    assert snapshot.current_tool == "file_grep"
    assert snapshot.tokens_used == 1_200
    assert snapshot.tool_count == 3
    assert snapshot.retry_count == 1
    assert snapshot.delivery_status == "acknowledged"
    assert snapshot.delivery_receipt == "receipt-1"

    assert snapshot == ExecutionControl.get("agent:parent:explorer")
  end

  test "updates are monotonic and preserve fields omitted by later lifecycle events" do
    :ok = ExecutionControl.start("worker", %{parent_session_id: "parent", task: "Work"})
    :ok = ExecutionControl.progress("worker", %{tokens_used: 50, tool_count: 2})
    :ok = ExecutionControl.progress("worker", %{tokens_used: 20, tool_count: 1})
    :ok = ExecutionControl.finish("worker", :failed, %{failure_count: 1, duration_ms: 900})

    snapshot = ExecutionControl.get("worker")
    assert snapshot.tokens_used == 50
    assert snapshot.tool_count == 2
    assert snapshot.failure_count == 1
    assert snapshot.duration_ms == 900
    assert snapshot.status == "failed"
    assert snapshot.task == "Work"
  end

  test "increments cumulative counters atomically" do
    assert :ok = ExecutionControl.start("worker-counters", %{})
    assert :ok = ExecutionControl.increment("worker-counters", :failure_count)
    assert :ok = ExecutionControl.increment("worker-counters", :failure_count)
    assert ExecutionControl.get("worker-counters").failure_count == 2
  end

  test "durable delivery changes are replayed to the parent TUI" do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:parent")

    :ok =
      ExecutionControl.start("worker", %{
        parent_session_id: "parent",
        task: "Work",
        model_reason: "tool-capable route"
      })

    :ok = ExecutionControl.progress("worker", %{active_skills: ["diagnose"], tool_count: 2})
    :ok = ExecutionControl.delivery("worker", "receipt-1", :acknowledged)
    :ok = ExecutionControl.broadcast("worker", "parent")

    assert_receive {:osa_event,
                    %{
                      event: "orchestrator_agent_progress",
                      agent_name: "worker",
                      active_skills: ["diagnose"],
                      model_reason: "tool-capable route",
                      delivery_status: "acknowledged",
                      tool_uses: 2
                    }}
  end
end
