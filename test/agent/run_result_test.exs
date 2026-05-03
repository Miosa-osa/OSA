defmodule OptimalSystemAgent.Agent.RunResultTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.RunResult

  test "normalizes the full structured subagent result contract" do
    result =
      RunResult.new(%{
        agent_id: "agent:parent:1",
        parent_session_id: "parent",
        role: :explorer,
        status: "completed",
        summary: "Mapped the agent system.",
        files_inspected: ["lib/a.ex", "lib/a.ex", ""],
        files_changed: nil,
        findings: ["RunStore is the lifecycle source"],
        commands_run: ["mix test"],
        tests_run: ["mix test test/agent/run_result_test.exs"],
        blockers: [],
        errors: [],
        assumptions: ["No external services"],
        next_actions: ["Wire TUI inspector"],
        verification: %{tests: :passed},
        confidence: 101,
        tool_count: 3,
        tokens_used: 1200,
        duration_ms: 42,
        transcript_path: "/tmp/run.md",
        worktree: nil
      })

    assert result.role == "explorer"
    assert result.status == :completed
    assert result.files_inspected == ["lib/a.ex"]
    assert result.files_changed == []
    assert result.confidence == 100
    assert result.verification == %{tests: :passed}
  end

  test "failure preserves metadata and records the inspected reason" do
    result =
      RunResult.failure(
        %{
          agent_id: "agent:parent:2",
          parent_session_id: "parent",
          role: "tester",
          tool_count: 2,
          tokens_used: 500,
          duration_ms: 10,
          transcript_path: "/tmp/run.md"
        },
        :timeout
      )

    assert result.status == :failed
    assert result.summary =~ "tester failed"
    assert result.errors == [":timeout"]
    assert result.tool_count == 2
  end
end
