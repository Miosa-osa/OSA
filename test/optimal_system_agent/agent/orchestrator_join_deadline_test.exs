defmodule OptimalSystemAgent.Agent.OrchestratorJoinDeadlineTest do
  @moduledoc """
  The outer await must not brutal-kill the process that persists the transcript.

  `execute_and_collect/6` runs INSIDE the spawned task, and it is where
  `force_terminate_orphan/1`, `RunStore.save_messages/3` and
  `RunStore.complete/2` live. Both the outer `Task.await` and the inner join
  defaulted to `@default_subagent_timeout_ms`, but the OUTER clock starts first
  — so `Task.shutdown(task, :brutal_kill)` always won the race, the inner
  timeout's cleanup path was dead code, the child's transcript snapshot (exactly
  what `resume_subagent/2` needs) was never written, and the run row stayed
  `:running` forever.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator

  setup do
    prev = Application.get_env(:optimal_system_agent, :subagent_join_grace_ms)
    Application.put_env(:optimal_system_agent, :subagent_join_grace_ms, 250)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, :subagent_join_grace_ms)
        v -> Application.put_env(:optimal_system_agent, :subagent_join_grace_ms, v)
      end
    end)

    :ok
  end

  defp task(fun) do
    Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fun)
  end

  describe "the outer deadline is derived from the inner one" do
    test "a configured await_timeout SHORTER than the inner join does not win the race" do
      # await_timeout 10ms, inner join 300ms. The old code awaited 10ms and
      # brutal-killed; the work (and its persistence) never happened.
      t =
        task(fn ->
          Process.sleep(200)
          {:ok, "persisted"}
        end)

      assert Orchestrator.join_subagent_task(t, 10, 300) == {:ok, "persisted"}
    end

    test "an explicitly LONGER await_timeout is still honoured" do
      t =
        task(fn ->
          Process.sleep(150)
          {:ok, "slow"}
        end)

      assert Orchestrator.join_subagent_task(t, 5_000, 0) == {:ok, "slow"}
    end
  end

  describe "the post-deadline grace lets cleanup finish before anything is killed" do
    test "a task that lands inside the grace window still returns its value" do
      # outer = max(10, 0 + 250) = 250ms; the task finishes at ~400ms, i.e.
      # inside the following 250ms grace rather than before the deadline.
      t =
        task(fn ->
          Process.sleep(400)
          {:ok, "persisted late"}
        end)

      assert Orchestrator.join_subagent_task(t, 10, 0) == {:ok, "persisted late"}
    end

    test "a task still stuck after the grace is reaped and reported as a FAILURE" do
      t =
        task(fn ->
          Process.sleep(30_000)
          {:ok, "never"}
        end)

      assert Orchestrator.join_subagent_task(t, 10, 0) == {:error, :timeout}
    end

    test "a crashing task is reported as crashed, not as success" do
      t = task(fn -> exit(:boom) end)

      assert {:error, {:crashed, _}} = Orchestrator.join_subagent_task(t, 10, 0)
    end
  end

  describe "subagent_join_timeout_ms/1" do
    test "prefers the per-call override" do
      assert Orchestrator.subagent_join_timeout_ms(%{timeout_ms: 1234}) == 1234
    end

    test "falls back to the configured default" do
      prev = Application.get_env(:optimal_system_agent, :subagent_join_timeout_ms)
      Application.put_env(:optimal_system_agent, :subagent_join_timeout_ms, 4321)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :subagent_join_timeout_ms)
          v -> Application.put_env(:optimal_system_agent, :subagent_join_timeout_ms, v)
        end
      end)

      assert Orchestrator.subagent_join_timeout_ms(%{}) == 4321
    end
  end
end
