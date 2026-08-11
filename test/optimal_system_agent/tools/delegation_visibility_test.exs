defmodule OptimalSystemAgent.Tools.DelegationVisibilityTest do
  @moduledoc """
  Delegation used to fly blind in three ways: the parent could not see what a
  delegation cost, a background subagent could stall silently for hours, and a
  task too vague for any subagent to act on was dispatched anyway — burning a
  full subagent run to produce nothing.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler, as: Delegate

  describe "task quality gate" do
    test "a deictic task is rejected — a subagent shares none of the parent's context" do
      # BEFORE: normalize_tasks/1 rejected only blank strings, so "fix it" was a
      # valid fan-out entry and a whole subagent run was spent discovering that
      # "it" refers to nothing it can see.
      assert Delegate.task_quality_issue("fix it") =~ "references to context"
      assert Delegate.task_quality_issue("do that again") =~ "references to context"
      assert Delegate.task_quality_issue("recompile") =~ "names no concrete target"
      assert Delegate.task_quality_issue("continue") =~ "references to context"
      assert Delegate.task_quality_issue("same again") =~ "references to context"
      assert Delegate.task_quality_issue("") == "the task is empty"
      assert Delegate.task_quality_issue(nil) == "the task is not a string"
    end

    test "terse-but-complete instructions still pass" do
      # The bar rejects only what CANNOT succeed. A concrete verb+object is
      # actionable by a context-free subagent and must not be blocked.
      assert Delegate.task_quality_issue("run mix test") == nil
      assert Delegate.task_quality_issue("read lib/foo.ex") == nil
      assert Delegate.task_quality_issue("audit the auth module for IDOR") == nil

      assert Delegate.task_quality_issue("""
             Add a regression test for the CRLF drift case in FileEdit.Matcher
             and make sure `mix test` passes.
             """) == nil
    end

    test "a fan-out containing a vague task is refused before any subagent spawns" do
      result =
        Delegate.execute(
          %{
            "task" => "umbrella",
            "tasks" => [
              %{"prompt" => "audit lib/optimal_system_agent/auth for missing scope checks"},
              %{"prompt" => "fix it"}
            ],
            "__session_id__" => "quality-gate-test"
          },
          %OptimalSystemAgent.Tools.UseContext{
            session_id: "quality-gate-test",
            permission_tier: :full
          }
        )

      assert {:error, msg} = result
      assert msg =~ "refused 1 fan-out task(s)"
      assert msg =~ "tasks[1]"
      assert msg =~ "\"fix it\""
      # Names what went wrong AND the next step.
      assert msg =~ "Next step:"
      assert msg =~ "self-contained instruction"
      # The good task is not silently dropped — the whole call is refused so the
      # model rewrites and re-dispatches the batch intact.
      refute msg =~ "tasks[0]"
    end
  end

  describe "background stall detection" do
    setup do
      prev = [
        Application.get_env(:optimal_system_agent, :stall_poll_interval_ms),
        Application.get_env(:optimal_system_agent, :stall_threshold_starting_ms),
        Application.get_env(:optimal_system_agent, :stall_threshold_working_ms)
      ]

      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 20)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 40)
      Application.put_env(:optimal_system_agent, :stall_threshold_working_ms, 40)

      on_exit(fn ->
        [poll, starting, working] = prev
        Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, poll)
        Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, starting)
        Application.put_env(:optimal_system_agent, :stall_threshold_working_ms, working)
      end)

      :ok
    end

    defp start_run(parent_id, agent_id) do
      OptimalSystemAgent.Agent.RunStore.start_run(%{
        agent_id: agent_id,
        parent_session_id: parent_id,
        role: "background",
        task: "a long background job"
      })
    end

    test "a run that never runs a tool is reported as stalled in :starting" do
      parent_id = "stall-parent-#{System.unique_integer([:positive])}"
      agent_id = "agent:#{parent_id}:1"

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")
      start_run(parent_id, agent_id)

      # BEFORE: run_background/2 had NO stall detection at all. The only backstop
      # anywhere was the 2h join timeout — and a background run is never joined,
      # so a wedged child was silent indefinitely.
      Orchestrator.start_stall_watcher(parent_id, agent_id, "worker", "background")

      assert_receive {:osa_event, %{type: :background_agent_stalled} = ev}, 2_000
      assert ev.phase == :starting
      assert ev.agent_id == agent_id
      assert ev.message =~ "no progress"
      assert ev.message =~ "Next step:"
    end

    test "a run that ran tools and then went quiet is reported in :working" do
      parent_id = "stall-parent-#{System.unique_integer([:positive])}"
      agent_id = "agent:#{parent_id}:1"

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")
      start_run(parent_id, agent_id)
      OptimalSystemAgent.Agent.RunStore.progress(agent_id, "ran file_read", 3)

      Orchestrator.start_stall_watcher(parent_id, agent_id, "worker", "background")

      assert_receive {:osa_event, %{type: :background_agent_stalled} = ev}, 2_000
      assert ev.phase == :working
      assert ev.tool_count == 3
      # Phase-aware: the working-phase advice is about a hung TOOL, not setup.
      assert ev.message =~ "hung tool"
    end

    test "a run that keeps making progress is never reported stalled" do
      # The threshold must exceed the whole progress window, otherwise a slow
      # scheduler — not a stall — decides the outcome. 12 x 15ms = ~180ms of
      # progress against a 2s threshold and a 20ms poll.
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 2_000)
      Application.put_env(:optimal_system_agent, :stall_threshold_working_ms, 2_000)

      parent_id = "stall-parent-#{System.unique_integer([:positive])}"
      agent_id = "agent:#{parent_id}:1"

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")
      start_run(parent_id, agent_id)
      Orchestrator.start_stall_watcher(parent_id, agent_id, "worker", "background")

      for i <- 1..12 do
        OptimalSystemAgent.Agent.RunStore.progress(agent_id, "step #{i}", i)
        Process.sleep(15)
      end

      # Terminal now, so the watcher exits rather than outliving the test.
      OptimalSystemAgent.Agent.RunStore.complete(agent_id, %{
        agent_id: agent_id,
        status: :completed,
        summary: "done",
        duration_ms: 1
      })

      refute_received {:osa_event, %{type: :background_agent_stalled}}
    end

    test "the watcher stops once the run reaches a terminal status" do
      parent_id = "stall-parent-#{System.unique_integer([:positive])}"
      agent_id = "agent:#{parent_id}:1"

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")
      start_run(parent_id, agent_id)

      OptimalSystemAgent.Agent.RunStore.complete(agent_id, %{
        agent_id: agent_id,
        status: :completed,
        summary: "done",
        duration_ms: 1
      })

      Orchestrator.start_stall_watcher(parent_id, agent_id, "worker", "background")

      refute_receive {:osa_event, %{type: :background_agent_stalled}}, 300
    end
  end

  describe "per-delegation cost" do
    test "run_cost_usd/1 reads a run's recorded spend" do
      agent_id = "cost-test-#{System.unique_integer([:positive])}"

      OptimalSystemAgent.Agent.SessionPersistence.save_spend(agent_id, %{
        cost_usd: 0.1234,
        input_tokens: 100,
        output_tokens: 50,
        cache_creation_tokens: 0,
        cache_read_tokens: 0
      })

      assert_in_delta Orchestrator.run_cost_usd(agent_id), 0.1234, 0.00001
    end

    test "a run with no recorded spend reports 0.0, never crashes" do
      assert Orchestrator.run_cost_usd("no-such-run-#{System.unique_integer([:positive])}") == 0.0
      assert Orchestrator.run_cost_usd(nil) == 0.0
    end
  end
end
