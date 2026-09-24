defmodule OptimalSystemAgent.Agent.Loop.GoalVerifierSpotCheckTest do
  @moduledoc """
  VSM System 3* — sporadic, cheap audits ahead of the goal-completion
  skeptic panel.

  This is the direct regression test for the cost problem item 1 exists to
  fix: the goal-completion verifier used to spend a FULL N-skeptic panel
  (`GoalVerifier.verify/1`) on every `:candidate_complete` triage verdict,
  unconditionally. It now tries `SpotCheckAuditor`'s cheap tier first
  (`run_gate/1`'s `:candidate_complete` branch), and only pays for the panel
  when a spot check actually fails or the change is judged too risky for a
  sample to represent. Panel cost is measured directly: the stubbed
  `:goal_verifier_panel_runner` counts how many times it is actually invoked.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger

  setup do
    sid = "goal-spot-check-test-" <> Integer.to_string(System.unique_integer([:positive]))
    Ledger.reset(sid)
    GoalTracker.clear(sid)

    dir =
      Path.join(System.tmp_dir!(), "osa-goal-spot-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn ->
      Ledger.reset(sid)
      GoalTracker.clear(sid)
      File.rm_rf(dir)
      Application.delete_env(:optimal_system_agent, :goal_verifier_panel_runner)
      Application.delete_env(:optimal_system_agent, :goal_verifier_triage_runner)
      Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
    end)

    Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 12)

    {:ok, sid: sid, dir: dir}
  end

  defp base_state(sid, dir) do
    %{
      session_id: sid,
      working_dir: dir,
      iteration: 20,
      total_tool_calls: 3,
      messages: [%{role: "user", content: "implement the widget exporter"}]
    }
  end

  # Every real call to the panel counts against this — the exact $/action
  # cost the spot-check tier exists to avoid paying on the common case.
  defp counting_panel_runner(counter) do
    fn _sid, configs ->
      :counters.add(counter, 1, 1)

      Enum.map(configs, fn _ ->
        {:ok, ~s({"refuted": false, "off_track": false, "reason": "ok"})}
      end)
    end
  end

  defp candidate_complete_triage_runner do
    fn _state -> {:ok, ~s({"status": "candidate_complete", "reason": "looks done"})} end
  end

  describe "a clean, ledger-supported completion never pays for the panel" do
    test "the panel runner is invoked ZERO times when the evidence ledger already supports the claim",
         %{sid: sid, dir: dir} do
      path = Path.join(dir, "exporter.ex")
      File.write!(path, "defmodule Exporter do\nend\n")

      Ledger.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: true})

      Ledger.record(sid, %{
        tool: "shell_execute",
        args: %{"command" => "mix compile"},
        success: true
      })

      GoalTracker.start(sid, "implement the widget exporter")

      counter = :counters.new(1, [])

      Application.put_env(
        :optimal_system_agent,
        :goal_verifier_panel_runner,
        counting_panel_runner(counter)
      )

      Application.put_env(
        :optimal_system_agent,
        :goal_verifier_triage_runner,
        candidate_complete_triage_runner()
      )

      state = base_state(sid, dir)

      assert GoalVerifier.needs_verification?(state)
      assert GoalVerifier.skip_reason(state) == nil

      new_state = GoalVerifier.maybe_gate(state)

      assert :counters.get(counter, 1) == 0,
             "a clean, ledger-supported completion must not spawn the skeptic panel at all"

      # The gate still advanced the run counter (a round happened — it was
      # just the cheap one) and did NOT append an "incomplete" directive.
      assert Map.get(new_state, :goal_verifier_runs, 0) >= 1
      refute Enum.any?(new_state.messages, &(Map.get(&1, :role) == "system"))
    end
  end

  describe "a spot check that fails still escalates to the full panel — unchanged behavior" do
    test "an untested write escalates to the panel, exactly as before this tier existed", %{
      sid: sid,
      dir: dir
    } do
      path = Path.join(dir, "exporter.ex")
      File.write!(path, "defmodule Exporter do\nend\n")

      # A write with NO check covering it — `SpotCheckAuditor` fails closed on
      # this for free (no I/O beyond the ledger itself), and the gate must
      # fall back to the exact panel behavior that existed before this tier.
      Ledger.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: true})
      GoalTracker.start(sid, "implement the widget exporter")

      counter = :counters.new(1, [])

      Application.put_env(
        :optimal_system_agent,
        :goal_verifier_panel_runner,
        counting_panel_runner(counter)
      )

      Application.put_env(
        :optimal_system_agent,
        :goal_verifier_triage_runner,
        candidate_complete_triage_runner()
      )

      state = base_state(sid, dir)
      _new_state = GoalVerifier.maybe_gate(state)

      assert :counters.get(counter, 1) > 0,
             "a spot check that cannot vouch for the claim must still escalate to the real panel"
    end
  end
end
