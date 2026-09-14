defmodule OptimalSystemAgent.Agent.Loop.GoalPauseSurfacesOnToolFreeReverifyTest do
  @moduledoc """
  G1 — a goal the cross-turn tracker JUST auto-paused (a real stall the
  skeptic panel found, or a persistently off-track verdict) must be SURFACED
  to the user, not silently absorbed behind the model's own last line of text.

  `GoalVerifier.maybe_wait_for_user/2` is the ONE reverify path that can
  transition a goal to `:paused` without ever passing back through the top of
  `ReactLoop.run/1` — its sibling, the tool-called path (`maybe_gate/1`),
  always re-enters `run/1` afterward, where the `iter > 0 and
  GoalTracker.paused?/1` clause already halts with the reason and gaps. This
  file exercises the ONE call-site fix that closes the gap: the tool-call-free
  handler (`handle_result({:ok, %{tool_calls: []}}, ...)`) now checks for a
  FRESH pause transition right after `maybe_wait_for_user/2` runs, instead of
  falling straight through to `finish_turn/2` on the model's own answer.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  setup do
    saved =
      for key <- [
            :default_provider,
            :max_iterations,
            :goal_tracker_enabled,
            :goal_verifier_enabled,
            :goal_verifier_panel_runner,
            :goal_verifier_triage_runner,
            :goal_verifier_stall_threshold,
            :goal_tracker_reverify_after,
            :compaction_max_continues,
            :proactive_compaction_enabled,
            :mock_provider_final_text
          ],
          into: %{},
          do: {key, Application.fetch_env(:optimal_system_agent, key)}

    prev_env = System.get_env("OSA_DEFAULT_PROVIDER")
    System.put_env("OSA_DEFAULT_PROVIDER", "mock")
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 12)
    Application.put_env(:optimal_system_agent, :goal_tracker_enabled, true)
    Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
    Application.put_env(:optimal_system_agent, :proactive_compaction_enabled, false)
    # Real usage spaces panel rounds `reverify_after` TURNS apart (default 8),
    # so two consecutive rounds happen across many separate top-level turns,
    # not within one. This test pre-seeds round 1 directly and drives round 2
    # through a single `ReactLoop.run/1` call, so the cadence cooldown must be
    # disabled or `reverify_due?/1` would defer round 2 for 8 more turns.
    Application.put_env(:optimal_system_agent, :goal_tracker_reverify_after, 0)

    Application.put_env(
      :optimal_system_agent,
      :mock_provider_final_text,
      "Still waiting on the security scan."
    )

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, v}} -> Application.put_env(:optimal_system_agent, key, v)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)

      case prev_env do
        nil -> System.delete_env("OSA_DEFAULT_PROVIDER")
        v -> System.put_env("OSA_DEFAULT_PROVIDER", v)
      end
    end)

    :ok
  end

  defp sid, do: "goal-tool-free-pause-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      # `iteration: 0` — a brand-new top-level turn, exactly what a user's
      # freshly-typed message looks like. `iteration > 0` would trip the
      # OTHER, pre-existing halt (`run/1`'s own `iter > 0 and
      # GoalTracker.paused?/1` clause) before the model is ever called at
      # all, which is not what either test here is about.
      iteration: 0,
      auto_continues: 0,
      messages: [%{role: "user", content: "still waiting?"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  defp stub_triage_candidate_complete do
    Application.put_env(
      :optimal_system_agent,
      :goal_verifier_triage_runner,
      fn _state -> {:ok, ~s({"status": "candidate_complete"})} end
    )
  end

  defp stub_panel_refuting(gaps) do
    Application.put_env(:optimal_system_agent, :goal_verifier_panel_runner, fn _sid, configs ->
      Enum.map(configs, fn _ ->
        {:ok, ~s({"refuted": true, "off_track": false, "reason": #{Jason.encode!(hd(gaps))}})}
      end)
    end)
  end

  test "a fresh no_progress pause reached via the tool-call-free reverify path is surfaced, not swallowed" do
    session_id = sid()
    GoalTracker.start(session_id, "run the security scan and report back")
    gaps = ["lib/scanner.ex still has no report/1"]

    # Round 1 establishes the fingerprint (pre-seeded directly — this test is
    # about the SECOND round, reached through the real loop, tripping the
    # stall and being surfaced).
    GoalTracker.advance(session_id, %GoalVerifier.Result{
      verdict: :incomplete,
      reason: "not yet",
      gaps: gaps
    })

    refute GoalTracker.paused?(session_id)

    stub_triage_candidate_complete()
    stub_panel_refuting(gaps)

    {response, _state} = ReactLoop.run(base_state(session_id))

    assert GoalTracker.paused?(session_id), "the second identical-gap round should have stalled"
    assert GoalTracker.snapshot(session_id).pause_reason == :no_progress

    refute response == "Still waiting on the security scan.",
           "the model's own text must not be shown in place of the pause notice"

    assert response =~ "no measurable progress"
    assert response =~ "lib/scanner.ex still has no report/1"

    GoalTracker.reset(session_id)
  end

  test "a goal already dormant-paused before the turn started is NOT re-announced over a real answer" do
    session_id = sid()
    GoalTracker.start(session_id, "run the security scan and report back")
    GoalTracker.pause(session_id, :user)
    assert GoalTracker.paused?(session_id)

    # No triage/panel stub needed — `goal_was_driving?` must already be false
    # (the goal was paused before this turn even started), so
    # `maybe_wait_for_user/2` itself must not spend anything, and the new
    # halt clause must not fire either.
    {response, _state} = ReactLoop.run(base_state(session_id))

    assert response == "Still waiting on the security scan.",
           "an unrelated turn's real answer must not be stomped by a stale pause notice"

    refute response =~ "no measurable progress"

    GoalTracker.reset(session_id)
  end
end
