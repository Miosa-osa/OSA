defmodule OptimalSystemAgent.Agent.Orchestrator.GoalDispatchTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Orchestrator.GoalDispatch

  # ── build_goal/3 ───────────────────────────────────────────────────

  describe "build_goal/3" do
    test "builds a goal with role, objective, and empty context" do
      goal = GoalDispatch.build_goal(:backend, "Add pagination to /api/users")

      assert goal.role == :backend
      assert goal.objective == "Add pagination to /api/users"
      assert goal.context.files == []
      assert goal.context.constraints == []
      assert goal.context.prior_results == %{}
      assert goal.context.tools == []
      assert %DateTime{} = goal.built_at
    end

    test "builds a goal with full context map" do
      context = %{
        files: ["lib/api/users.ex", "test/api/users_test.exs"],
        constraints: ["backward-compatible", "no breaking changes"],
        prior_results: %{"explorer" => "Found 3 endpoints"},
        tools: ["file_read", "file_write", "shell_execute"],
        dependencies: ["explorer"],
        metadata: %{wave: 2}
      }

      goal = GoalDispatch.build_goal(:frontend, "Build user list component", context)

      assert goal.role == :frontend
      assert goal.objective == "Build user list component"
      assert goal.context.files == ["lib/api/users.ex", "test/api/users_test.exs"]
      assert goal.context.constraints == ["backward-compatible", "no breaking changes"]
      assert goal.context.prior_results == %{"explorer" => "Found 3 endpoints"}
      assert goal.context.tools == ["file_read", "file_write", "shell_execute"]
      assert goal.context.dependencies == ["explorer"]
      assert goal.context.metadata == %{wave: 2}
    end

    test "trims whitespace from task description" do
      goal = GoalDispatch.build_goal(:qa, "  Run integration tests  ")
      assert goal.objective == "Run integration tests"
    end

    test "builds goals for various roles" do
      roles = [:lead, :backend, :frontend, :data, :design, :infra, :qa, :red_team, :services]

      for role <- roles do
        goal = GoalDispatch.build_goal(role, "Task for #{role}")
        assert goal.role == role
        assert goal.objective == "Task for #{role}"
      end
    end

    test "normalizes missing context keys to defaults" do
      goal = GoalDispatch.build_goal(:backend, "Fix bug", %{files: ["a.ex"]})

      assert goal.context.files == ["a.ex"]
      assert goal.context.constraints == []
      assert goal.context.prior_results == %{}
      assert goal.context.tools == []
    end
  end

  # ── dispatch/2 ─────────────────────────────────────────────────────

  describe "dispatch/2" do
    test "produces a prompt with goal section" do
      goal = GoalDispatch.build_goal(:backend, "Implement caching layer")
      prompt = GoalDispatch.dispatch(goal)

      assert prompt =~ "## Goal"
      assert prompt =~ "Backend"
      assert prompt =~ "Implement caching layer"
      assert prompt =~ "You decide the approach"
    end

    test "includes context when files are provided" do
      goal =
        GoalDispatch.build_goal(:backend, "Fix N+1 query", %{
          files: ["lib/repo/users.ex", "lib/repo/orders.ex"]
        })

      prompt = GoalDispatch.dispatch(goal)

      assert prompt =~ "## Context"
      assert prompt =~ "Relevant Files"
      assert prompt =~ "`lib/repo/users.ex`"
      assert prompt =~ "`lib/repo/orders.ex`"
    end

    test "includes prior agent results in context" do
      goal =
        GoalDispatch.build_goal(:backend, "Fix the bug", %{
          prior_results: %{
            "explorer" => "Found root cause in auth.ex line 42",
            "reviewer" => "Confirmed the race condition"
          }
        })

      prompt = GoalDispatch.dispatch(goal)

      assert prompt =~ "Prior Agent Results"
      assert prompt =~ "**explorer**"
      assert prompt =~ "Found root cause in auth.ex line 42"
      assert prompt =~ "**reviewer**"
      assert prompt =~ "Confirmed the race condition"
    end

    test "includes tools section when tools are specified" do
      goal =
        GoalDispatch.build_goal(:infra, "Deploy service", %{
          tools: ["shell_execute", "file_read", "web_search"]
        })

      prompt = GoalDispatch.dispatch(goal)

      assert prompt =~ "## Available Tools"
      assert prompt =~ "shell_execute, file_read, web_search"
    end

    test "includes constraints section" do
      goal =
        GoalDispatch.build_goal(:backend, "Refactor auth", %{
          constraints: ["no downtime", "backward-compatible API"]
        })

      prompt = GoalDispatch.dispatch(goal)

      assert prompt =~ "## Constraints"
      assert prompt =~ "- no downtime"
      assert prompt =~ "- backward-compatible API"
    end

    test "includes execution frame from agent config" do
      goal = GoalDispatch.build_goal(:backend, "Build API")

      prompt = GoalDispatch.dispatch(goal, %{name: "backend-go", tier: :specialist})

      assert prompt =~ "## Execution"
      assert prompt =~ "Agent: backend-go"
      assert prompt =~ "Tier: specialist"
    end

    test "omits empty sections" do
      goal = GoalDispatch.build_goal(:backend, "Simple task")
      prompt = GoalDispatch.dispatch(goal)

      refute prompt =~ "## Context"
      refute prompt =~ "## Available Tools"
      refute prompt =~ "## Constraints"
      refute prompt =~ "## Execution"
    end

    test "does not include step-by-step instructions" do
      goal =
        GoalDispatch.build_goal(:backend, "Add rate limiting", %{
          files: ["lib/api/router.ex"],
          tools: ["file_read", "file_write"],
          constraints: ["100 req/min default"]
        })

      prompt = GoalDispatch.dispatch(goal, %{name: "backend-go", tier: :specialist})

      # Should NOT contain prescriptive step sequences
      refute prompt =~ "Step 1"
      refute prompt =~ "Step 2"
      refute prompt =~ "First, "
      refute prompt =~ "Then, "
      refute prompt =~ "Finally, "
    end
  end

  # ── merge_results/1 ────────────────────────────────────────────────

  describe "merge_results/1" do
    test "merges all-success results" do
      results = [
        %{agent: "backend", status: :ok, output: "Added pagination with cursor support"},
        %{agent: "test", status: :ok, output: "Wrote 12 unit tests, all passing"}
      ]

      merged = GoalDispatch.merge_results(results)

      assert merged.status == :ok
      assert length(merged.succeeded) == 2
      assert merged.failed == []
      assert merged.synthesis =~ "backend"
      assert merged.synthesis =~ "Added pagination"
      assert merged.synthesis =~ "test"
      assert merged.synthesis =~ "12 unit tests"
    end

    test "merges all-failure results" do
      results = [
        %{agent: "backend", status: :error, output: "LLM timeout after 3 retries"},
        %{agent: "test", status: :error, output: "Could not connect to test DB"}
      ]

      merged = GoalDispatch.merge_results(results)

      assert merged.status == :error
      assert merged.succeeded == []
      assert length(merged.failed) == 2
      assert merged.synthesis =~ "FAILED"
      assert merged.synthesis =~ "LLM timeout"
    end

    test "merges mixed success/failure results" do
      results = [
        %{agent: "backend", status: :ok, output: "Implemented feature X"},
        %{agent: "test", status: :error, output: "Test runner crashed"},
        %{agent: "reviewer", status: :ok, output: "Code looks clean"}
      ]

      merged = GoalDispatch.merge_results(results)

      assert merged.status == :partial
      assert length(merged.succeeded) == 2
      assert length(merged.failed) == 1
      assert merged.synthesis =~ "Completed"
      assert merged.synthesis =~ "Failed"
      assert merged.synthesis =~ "test (FAILED)"
    end

    test "handles empty results list" do
      merged = GoalDispatch.merge_results([])

      assert merged.status == :error
      assert merged.synthesis == "No agent results to merge."
      assert merged.succeeded == []
      assert merged.failed == []
    end

    test "normalizes results with missing metadata" do
      results = [
        %{agent: "backend", status: :ok, output: "Done"}
      ]

      merged = GoalDispatch.merge_results(results)

      assert merged.status == :ok
      [result] = merged.succeeded
      assert result.metadata == %{}
    end

    test "preserves metadata when present" do
      results = [
        %{agent: "backend", status: :ok, output: "Done", metadata: %{tokens: 5000, tool_uses: 3}}
      ]

      merged = GoalDispatch.merge_results(results)

      [result] = merged.succeeded
      assert result.metadata == %{tokens: 5000, tool_uses: 3}
    end

    test "handles single result" do
      merged = GoalDispatch.merge_results([
        %{agent: "solo", status: :ok, output: "All done"}
      ])

      assert merged.status == :ok
      assert length(merged.succeeded) == 1
      assert merged.synthesis =~ "solo"
    end
  end
end
