defmodule OptimalSystemAgent.Agent.OrchestratorResumeTest do
  @moduledoc """
  WS7 — subagent resume-with-context regression tests: message snapshot
  round-trip, recent-actions trail, unresolved tool_use filtering, and the
  resume guard rails.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_resume_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end

  test "saved child messages round-trip losslessly with metadata" do
    messages = [
      %{role: "user", content: "hi"},
      %{role: "assistant", content: "hello", tool_calls: []}
    ]

    RunStore.save_messages("agent:p:rt", messages, %{worktree_path: "/tmp/x", role: "tester"})

    assert {:ok, ^messages, %{worktree_path: "/tmp/x", role: "tester"}} =
             RunStore.load_messages("agent:p:rt")
  end

  test "load_messages on an unknown agent returns not_found" do
    assert {:error, :not_found} = RunStore.load_messages("agent:p:nope")
  end

  test "progress keeps a newest-first recent_actions trail capped at 5, deduping repeats" do
    RunStore.start_run(%{agent_id: "agent:p:trail", parent_session_id: "p", role: "r", task: "t"})
    for n <- 1..7, do: RunStore.progress("agent:p:trail", "act#{n}", n)
    # Consecutive duplicate must not double up.
    RunStore.progress("agent:p:trail", "act7", 8)

    assert %{recent_actions: ["act7", "act6", "act5", "act4", "act3"]} =
             RunStore.get("agent:p:trail")
  end

  test "filter_unresolved_tool_uses strips orphan calls and orphan results" do
    messages = [
      %{role: "user", content: "go"},
      %{role: "assistant", content: "", tool_calls: [%{id: "a", name: "x"}]},
      %{role: "tool", tool_call_id: "a", content: "ok"},
      %{role: "tool", tool_call_id: "ghost", content: "orphan"},
      %{role: "assistant", content: "", tool_calls: [%{id: "b", name: "y"}]}
    ]

    filtered = Orchestrator.filter_unresolved_tool_uses(messages)

    assert Enum.map(filtered, & &1.role) == ["user", "assistant", "tool"]
    refute Enum.any?(filtered, fn m -> m[:tool_call_id] == "ghost" end)
  end

  test "assistant text survives even when its tool_calls are all unresolved" do
    messages = [
      %{role: "assistant", content: "partial findings", tool_calls: [%{id: "z", name: "x"}]}
    ]

    assert [%{content: "partial findings", tool_calls: []}] =
             Orchestrator.filter_unresolved_tool_uses(messages)
  end

  test "resume_subagent errors on an unknown run" do
    assert {:error, _} = Orchestrator.resume_subagent("agent:p:missing", "continue")
  end
end
