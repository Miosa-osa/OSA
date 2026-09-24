defmodule OptimalSystemAgent.Agent.Orchestrator.SubagentPainEscalationTest do
  @moduledoc """
  VSM item 9 — every subagent is itself a viable system: it gets its own
  stall/pain detection, INHERITED from the parent's configuration and SCALED
  DOWN by tier and delegation depth, and escalates pain to the parent as a
  structured `{cause, severity}` event distinct from (and alongside) the
  subsystem-specific lifecycle event.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Orchestrator

  setup do
    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :stall_poll_interval_ms)
      Application.delete_env(:optimal_system_agent, :stall_threshold_starting_ms)
      Application.delete_env(:optimal_system_agent, :stall_threshold_working_ms)
      Application.delete_env(:optimal_system_agent, :stall_hard_stop_ms)
    end)

    parent = "pain-parent-" <> Integer.to_string(System.unique_integer([:positive]))
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")
    {:ok, parent: parent}
  end

  defp start_running_row(parent, id) do
    RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "tester", task: "work"})
  end

  describe "recursion-scaled stall thresholds (Tier.tier_scale/1, Tier.depth_scale/1)" do
    test "a :utility worker several delegations deep stalls out faster than a :specialist direct child" do
      # Same CONFIGURED base threshold for both — the scale factor is the only
      # thing that differs between the two watchers below.
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 20)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 200)

      fast_scale = Tier.tier_scale(:utility) * Tier.depth_scale(3)
      slow_scale = Tier.tier_scale(:specialist) * Tier.depth_scale(1)

      assert fast_scale < slow_scale,
             "a deep :utility worker must scale to a SMALLER threshold than a direct " <>
               ":specialist child, or this test cannot demonstrate the difference"

      parent_fast = "pain-fast-" <> Integer.to_string(System.unique_integer([:positive]))
      parent_slow = "pain-slow-" <> Integer.to_string(System.unique_integer([:positive]))
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_fast}")
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_slow}")

      fast_id = "pain-fast-run-" <> Integer.to_string(System.unique_integer([:positive]))
      slow_id = "pain-slow-run-" <> Integer.to_string(System.unique_integer([:positive]))

      start_running_row(parent_fast, fast_id)
      start_running_row(parent_slow, slow_id)

      :ok = Orchestrator.start_stall_watcher(parent_fast, fast_id, "fast", "tester", :utility, 3)

      :ok =
        Orchestrator.start_stall_watcher(parent_slow, slow_id, "slow", "tester", :specialist, 1)

      # The deep utility worker's scaled threshold is well under 200ms; the
      # direct specialist child's is NOT (it stays at the full 200ms) — so
      # within this window only the fast one should have nudged.
      assert_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^fast_id}}, 400

      refute_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^slow_id}}, 100

      RunStore.complete(fast_id, %{agent_id: fast_id, status: :completed, summary: "done"})
      RunStore.complete(slow_id, %{agent_id: slow_id, status: :completed, summary: "done"})
    end
  end

  describe "structured pain escalation alongside the subsystem-specific event" do
    test "a stall reports :subagent_pain (cause: :stalled, severity: :warning) alongside :background_agent_stalled",
         %{parent: parent} do
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 20)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 30)

      id = "pain-stall-run-" <> Integer.to_string(System.unique_integer([:positive]))
      start_running_row(parent, id)

      :ok = Orchestrator.start_stall_watcher(parent, id, "hanger", "tester")

      assert_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^id}}, 5_000

      assert_receive {:osa_event, %{type: :background_agent_stalled, agent_id: ^id}}, 5_000

      assert_receive {:osa_event,
                      %{type: :subagent_pain, agent_id: ^id, cause: :stalled, severity: :warning}},
                     1_000,
                     "a stall must escalate the generic structured pain event, not just the " <>
                       "background_agent_stalled lifecycle event"

      RunStore.complete(id, %{agent_id: id, status: :completed, summary: "done"})
    end

    test "a hard stall reports :subagent_pain (cause: :stall_hard_stop, severity: :critical)",
         %{parent: parent} do
      Application.put_env(:optimal_system_agent, :stall_poll_interval_ms, 20)
      Application.put_env(:optimal_system_agent, :stall_threshold_starting_ms, 30)
      Application.put_env(:optimal_system_agent, :stall_hard_stop_ms, 40)

      id = "pain-hard-run-" <> Integer.to_string(System.unique_integer([:positive]))
      start_running_row(parent, id)

      :ok = Orchestrator.start_stall_watcher(parent, id, "hanger", "tester")

      assert_receive {:osa_event, %{type: :background_agent_nudged, agent_id: ^id}}, 5_000
      assert_receive {:osa_event, %{type: :background_agent_auto_stopped, agent_id: ^id}}, 5_000

      assert_receive {:osa_event,
                      %{
                        type: :subagent_pain,
                        agent_id: ^id,
                        cause: :stall_hard_stop,
                        severity: :critical
                      }},
                     1_000
    end
  end
end
