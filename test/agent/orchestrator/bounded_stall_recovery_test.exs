defmodule OptimalSystemAgent.Agent.Orchestrator.BoundedStallRecoveryTest do
  @moduledoc """
  Two robustness properties for long-running/background agents.

  1. **A first stall is nudged, not just narrated.** The observe-only watcher
     used to escalate a stall to the parent and otherwise do nothing to help the
     child. Now the FIRST detected stall triggers exactly one non-destructive
     nudge (`Loop.poke/1`, the parent's normal idle-wake) before any escalation.
     The nudge is sent at most once — a healthy-but-slow child that gets poked is
     fine, and it must not be poked on every poll. If the child stalls again
     after the nudge, the watcher falls back to the original observe-only
     behavior (emit `:background_agent_stalled`, keep watching). It never kills
     and never restarts.

  2. **Completion events say whether the task actually succeeded.** A terminal
     background event now carries `task_completed` — `true` only when the run
     returned `{:ok, _}`, `false` on error/timeout/cancel — so $/completed-task
     is computed over genuine completions rather than counting failures as done.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :max_fleet_agents)
      Application.delete_env(:optimal_system_agent, :stall_poll_interval_ms)
      Application.delete_env(:optimal_system_agent, :stall_threshold_starting_ms)
      Application.delete_env(:optimal_system_agent, :stall_threshold_working_ms)
      Application.delete_env(:optimal_system_agent, :stall_hard_stop_ms)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    parent = "stallrec-" <> Integer.to_string(System.unique_integer([:positive]))
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")
    {:ok, parent: parent}
  end

  describe "bounded, non-destructive stall recovery" do
    test "the first stall is nudged exactly once, then falls back to observe-only",
         %{parent: parent} do
      # Tight timings so the watcher's phase-aware clock fires in the test
      # budget instead of minutes. The row never changes its fingerprint, so it
      # is stalled from the first repeat poll onward.
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 30)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 60)

      id = "stallrec-run-" <> Integer.to_string(System.unique_integer([:positive]))

      # A :running row with zero tools => phase :starting, and no live Loop, so
      # `Loop.poke/1` is a safe no-op — we are asserting the recovery DECISION,
      # not the child's reaction.
      RunStore.start_run(%{
        agent_id: id,
        parent_session_id: parent,
        role: "tester",
        task: "hang forever"
      })

      :ok = Orchestrator.start_stall_watcher(parent, id, "hanger", "tester")

      # FIRST stall -> one nudge, before any stalled escalation.
      assert_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^id, phase: :starting}},
                     5_000,
                     "the first stall must trigger one non-destructive nudge"

      # SECOND stall (still no progress) -> the original observe-only report.
      assert_receive {:osa_event, %{type: :background_agent_stalled, agent_id: ^id}},
                     5_000,
                     "a stall that persists past the nudge must fall back to the stalled event"

      # The nudge is never repeated for the same uninterrupted stall — a
      # healthy-but-slow child is poked at most once, never on every poll.
      refute_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^id}}, 300

      # Terminal row => the watcher exits on its next poll. Never killed here.
      RunStore.complete(id, %{agent_id: id, status: :completed, summary: "done"})
    end
  end

  describe "hard auto-stop of an unrecoverable hang" do
    test "an agent with no progress past the hard threshold is auto-stopped and cancelled",
         %{parent: parent} do
      # Tight timings: nudge fires, then the hard-stop threshold trips a couple
      # polls later. A real hang is 2h; here it is milliseconds.
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 30)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 40)
      Application.put_env(:optimal_system_agent, :stall_hard_stop_ms, 50)

      id = "stallhard-run-" <> Integer.to_string(System.unique_integer([:positive]))

      RunStore.start_run(%{
        agent_id: id,
        parent_session_id: parent,
        role: "tester",
        task: "hang forever"
      })

      :ok = Orchestrator.start_stall_watcher(parent, id, "hanger", "tester")

      # It nudges first (bounded recovery), then — still no progress past the
      # hard threshold — auto-stops the dead hang instead of watching forever.
      assert_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^id}}, 5_000

      assert_receive {:osa_event, %{type: :background_agent_auto_stopped, agent_id: ^id} = ev},
                     5_000,
                     "a hang with no progress past the hard threshold must auto-stop"

      assert ev.summary =~ "Auto-stopped"

      # The run is recorded cancelled (same terminal state task_stop produces),
      # so the coordinator sees it done without a manual task_stop.
      assert %{status: :cancelled} = RunStore.get(id)
    end

    test "a healthy agent that keeps progressing is NEVER auto-stopped", %{parent: parent} do
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 30)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 40)
      Application.put_env(:optimal_system_agent, :stall_hard_stop_ms, 50)

      id = "stallhealthy-run-" <> Integer.to_string(System.unique_integer([:positive]))
      RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "tester", task: "work"})
      :ok = Orchestrator.start_stall_watcher(parent, id, "worker", "tester")

      # Keep changing the fingerprint (real progress) across the window the
      # hard-stop would otherwise fire in.
      for n <- 1..6 do
        RunStore.progress(id, "did #{n}", n)
        Process.sleep(40)
      end

      refute_receive {:osa_event, %{type: :background_agent_auto_stopped, agent_id: ^id}}, 100
      assert %{status: :running} = RunStore.get(id)

      RunStore.complete(id, %{agent_id: id, status: :completed, summary: "done"})
    end
  end

  describe "completion events carry task_completed" do
    defp config(overrides \\ %{}) do
      Map.merge(
        %{
          task: "say hello",
          role: "tester",
          tier: :specialist,
          model: "mock-model-1.0",
          provider: :mock,
          working_dir: System.tmp_dir!()
        },
        overrides
      )
    end

    test "a successful background run reports task_completed: true", %{parent: parent} do
      Application.put_env(
        :optimal_system_agent,
        :max_fleet_agents,
        Orchestrator.live_agent_count() + 2
      )

      {:ok, id} = Orchestrator.run_background(parent, config())

      assert_receive {:osa_event, %{type: :background_agent_completed, agent_id: ^id} = ev},
                     20_000

      assert ev.task_completed == true,
             "a run that returned {:ok, _} must be marked completed so it counts " <>
               "toward $/completed-task; got #{inspect(Map.get(ev, :task_completed))}"
    end
  end
end
