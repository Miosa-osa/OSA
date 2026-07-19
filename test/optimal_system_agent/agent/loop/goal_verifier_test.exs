defmodule OptimalSystemAgent.Agent.Loop.GoalVerifierTest do
  @moduledoc """
  P1: independent goal-level verifier — separate read-only skeptic panel,
  majority-refute vote, run cap, and stall early-exit.

  The subagent runner is stubbed via `:goal_verifier_panel_runner` so these
  are pure unit tests — no real Loop GenServer / LLM call is spawned.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger

  setup do
    sid = "goal-verifier-test-#{System.unique_integer([:positive])}"
    Ledger.reset(sid)

    on_exit(fn ->
      Ledger.reset(sid)
      Application.delete_env(:optimal_system_agent, :goal_verifier_panel_runner)
      Application.delete_env(:optimal_system_agent, :goal_verifier_max_runs)
      Application.delete_env(:optimal_system_agent, :goal_verifier_stall_threshold)
      Application.delete_env(:optimal_system_agent, :goal_verifier_skeptic_count)
    end)

    {:ok, session_id: sid}
  end

  defp base_state(sid) do
    %{
      session_id: sid,
      working_dir: File.cwd!(),
      messages: [%{role: "user", content: "implement the widget exporter"}]
    }
  end

  defp mark_write(sid, path \\ "/tmp/goal_verifier_fixture.ex") do
    Ledger.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: true})
  end

  defp json_result(refuted, opts \\ []) do
    off_track = Keyword.get(opts, :off_track, false)
    reason = Keyword.get(opts, :reason, "gap #{System.unique_integer([:positive])}")

    {:ok,
     ~s({"refuted": #{refuted}, "off_track": #{off_track}, "reason": #{Jason.encode!(reason)}})}
  end

  defp stub_runner(fun) do
    Application.put_env(:optimal_system_agent, :goal_verifier_panel_runner, fun)
  end

  # An isolated, empty git repo — used where a test needs to assert on the
  # exact prompt text and must NOT be polluted by `git diff HEAD` of this
  # very (dirty, work-in-progress) development checkout.
  defp isolated_clean_repo do
    dir = Path.join(System.tmp_dir!(), "goal-verifier-clean-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # ── Gating ──────────────────────────────────────────────────────────────

  describe "needs_verification?/1" do
    test "false with no session_id" do
      refute GoalVerifier.needs_verification?(%{})
    end

    test "false when no accumulated write evidence", %{session_id: sid} do
      refute GoalVerifier.needs_verification?(base_state(sid))
    end

    test "true once a write has landed", %{session_id: sid} do
      mark_write(sid)
      assert GoalVerifier.needs_verification?(base_state(sid))
    end

    test "false once the run cap is exhausted", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_max_runs, 2)

      state = base_state(sid) |> Map.put(:goal_verifier_runs, 2)
      refute GoalVerifier.needs_verification?(state)
    end

    test "false once stalled", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      state = base_state(sid) |> Map.put(:goal_verifier_stall_count, 2)
      refute GoalVerifier.needs_verification?(state)
    end
  end

  # ── Majority-refute aggregation ──────────────────────────────────────────

  describe "verify/1 majority-refute vote" do
    test "3 skeptics, 2 refute -> :incomplete", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, configs ->
        assert length(configs) == 3

        [json_result(true), json_result(true), json_result(false)]
      end)

      {result, state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.refuted_count == 2
      assert result.total == 3
      assert state.goal_verifier_runs == 1
    end

    test "all 3 skeptics pass -> :complete", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(false), json_result(false), json_result(false)]
      end)

      {result, state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :complete
      assert result.refuted_count == 0
      assert state.goal_verifier_runs == 1
    end

    test "tie (e.g. 1 refute out of 2, forced via skeptic_count override) does not reach majority" do
      Application.put_env(:optimal_system_agent, :goal_verifier_skeptic_count, 2)
      sid = "goal-verifier-tie-#{System.unique_integer([:positive])}"
      Ledger.reset(sid)
      mark_write(sid)

      stub_runner(fn _sid, configs ->
        assert length(configs) == 2
        [json_result(true), json_result(false)]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      # needed = div(2,2)+1 = 2; only 1 refuted -> majority NOT reached -> :complete
      assert result.verdict == :complete
      Ledger.reset(sid)
    end

    test "majority refute AND majority off_track -> :off_track", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, off_track: true, reason: "prerequisite missing"),
          json_result(true, off_track: true, reason: "contradiction in goal"),
          json_result(false)
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :off_track
      assert result.refuted_count == 2
    end

    test "malformed / non-JSON skeptic response fails closed as a refute", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [{:ok, "I looked around and it seems fine, no structured answer here."},
         json_result(false),
         json_result(false)]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      # 1 fail-closed refute out of 3 does not reach majority (needed = 2)
      assert result.verdict == :complete
      assert result.refuted_count == 1
    end

    test "a crashed/errored skeptic counts as a refute, not silently dropped", %{
      session_id: sid
    } do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [{:error, :timeout}, json_result(true), json_result(false)]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.refuted_count == 2
      assert result.verdict == :incomplete
    end

    test "empty panel result fails closed to :incomplete", %{session_id: sid} do
      mark_write(sid)
      stub_runner(fn _sid, _configs -> [] end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.total == 0
    end
  end

  # ── Stall early-exit ──────────────────────────────────────────────────────

  describe "stall early-exit" do
    test "two identical gap fingerprints in a row trips the stall flag", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "missing test coverage"), json_result(true, reason: "missing test coverage"),
         json_result(false)]
      end)

      state = base_state(sid)

      {result1, state} = GoalVerifier.verify(state)
      assert result1.verdict == :incomplete
      refute GoalVerifier.stalled?(state)

      {result2, state} = GoalVerifier.verify(state)
      assert result2.verdict == :incomplete
      assert GoalVerifier.stalled?(state)

      # Once stalled, needs_verification?/1 must stop firing even with budget left.
      refute GoalVerifier.needs_verification?(state)
    end

    test "a changing gap fingerprint does not trip the stall flag", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      state = base_state(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "gap A"), json_result(true, reason: "gap A"), json_result(false)]
      end)

      {result1, state} = GoalVerifier.verify(state)
      assert result1.verdict == :incomplete
      refute GoalVerifier.stalled?(state)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "gap B (different)"),
         json_result(true, reason: "gap B (different)"), json_result(false)]
      end)

      {result2, state} = GoalVerifier.verify(state)
      assert result2.verdict == :incomplete
      refute GoalVerifier.stalled?(state)
    end

    test "reaching :complete resets the stall counter", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      state = base_state(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "same gap"), json_result(false), json_result(false)]
      end)

      {_r1, state} = GoalVerifier.verify(state)

      stub_runner(fn _sid, _configs ->
        [json_result(false), json_result(false), json_result(false)]
      end)

      {r2, state} = GoalVerifier.verify(state)
      assert r2.verdict == :complete
      assert state.goal_verifier_stall_count == 0
    end
  end

  # ── Run cap ────────────────────────────────────────────────────────────────

  describe "run cap" do
    test "needs_verification?/1 stops firing once the cap is hit", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_max_runs, 2)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "still broken #{System.unique_integer()}"), json_result(true), json_result(false)]
      end)

      state = base_state(sid)
      assert GoalVerifier.needs_verification?(state)

      {_r1, state} = GoalVerifier.verify(state)
      assert state.goal_verifier_runs == 1
      assert GoalVerifier.needs_verification?(state)

      {_r2, state} = GoalVerifier.verify(state)
      assert state.goal_verifier_runs == 2

      refute GoalVerifier.needs_verification?(state)
    end
  end

  # ── check/1 (single entry point for the loop) ───────────────────────────

  describe "check/1" do
    test "returns {:pass, state} on :complete", %{session_id: sid} do
      mark_write(sid)
      stub_runner(fn _sid, _configs -> [json_result(false), json_result(false), json_result(false)] end)

      assert {:pass, _state} = GoalVerifier.check(base_state(sid))
    end

    test "returns {:gate, directive, state} on :incomplete with gap details inlined", %{
      session_id: sid
    } do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "missing edge-case handling"), json_result(true, reason: "no tests"),
         json_result(false)]
      end)

      assert {:gate, directive, state} = GoalVerifier.check(base_state(sid))
      assert directive.role == "system"
      assert directive.content =~ "GOAL VERIFIER"
      assert directive.content =~ "missing edge-case handling"
      assert state.goal_verifier_prompts == 1
    end

    test "returns an off-track redirect nudge, not a keep-going nudge, on :off_track", %{
      session_id: sid
    } do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, off_track: true, reason: "goal contradicts existing architecture"),
          json_result(true, off_track: true, reason: "no such API exists"),
          json_result(false)
        ]
      end)

      assert {:gate, directive, _state} = GoalVerifier.check(base_state(sid))
      assert directive.content =~ "OFF-TRACK"
      assert directive.content =~ "materially different approach"
    end
  end

  # ── Skeptic prompt bias (finding #4) ────────────────────────────────────
  # The panel prompt used to say "if uncertain, REFUTE", biasing the skeptic
  # to keep the goal "not done" on mere uncertainty. It must now default to
  # NOT-REFUTED on uncertainty and only refute on concrete evidence.

  describe "skeptic prompt bias" do
    test "does not instruct the skeptic to refute on uncertainty", %{session_id: sid} do
      mark_write(sid)
      test_pid = self()

      stub_runner(fn _sid, configs ->
        send(test_pid, {:configs, configs})
        [json_result(false), json_result(false), json_result(false)]
      end)

      state = base_state(sid) |> Map.put(:working_dir, isolated_clean_repo())
      GoalVerifier.verify(state)

      assert_received {:configs, configs}
      assert [%{task: prompt} | _] = configs

      refute prompt =~ ~r/uncertain,?\s+REFUTE/i
      assert prompt =~ "Default to NOT-REFUTED when uncertain"
      assert prompt =~ "CONCRETE evidence"
    end
  end

  # ── Stall fingerprint stability (finding #10) ───────────────────────────
  # The old fingerprint hashed raw free-form LLM prose, so two rounds citing
  # the SAME underlying gap almost never trip stall detection because the
  # sentences are reworded. The new fingerprint is stable across paraphrased
  # reasons that cite the same concrete file/identifier.

  describe "stall fingerprint stability across paraphrased reasons (finding #10)" do
    test "two DIFFERENTLY WORDED reasons citing the same file trip the stall detector", %{
      session_id: sid
    } do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      state = base_state(sid)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, reason: "lib/foo/bar.ex is missing the new function entirely"),
          json_result(true, reason: "lib/foo/bar.ex is missing the new function entirely"),
          json_result(false)
        ]
      end)

      {result1, state} = GoalVerifier.verify(state)
      assert result1.verdict == :incomplete
      refute GoalVerifier.stalled?(state)

      # Same underlying gap (same file), completely reworded sentence — the
      # OLD prose-hash fingerprint would treat this as a brand new gap and
      # never trip stall. The new identifier-based fingerprint recognizes
      # the same file being cited and trips on round 2.
      stub_runner(fn _sid, _configs ->
        [
          json_result(true, reason: "still nothing was done about lib/foo/bar.ex, check again"),
          json_result(true, reason: "still nothing was done about lib/foo/bar.ex, check again"),
          json_result(false)
        ]
      end)

      {result2, state} = GoalVerifier.verify(state)
      assert result2.verdict == :incomplete
      assert GoalVerifier.stalled?(state)
    end

    test "reasons citing genuinely DIFFERENT files do not trip the stall detector", %{
      session_id: sid
    } do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_stall_threshold, 2)

      state = base_state(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "lib/foo/bar.ex is missing the new function"),
         json_result(true, reason: "lib/foo/bar.ex is missing the new function"), json_result(false)]
      end)

      {_result1, state} = GoalVerifier.verify(state)
      refute GoalVerifier.stalled?(state)

      stub_runner(fn _sid, _configs ->
        [json_result(true, reason: "lib/baz/qux.ex has an unrelated separate gap"),
         json_result(true, reason: "lib/baz/qux.ex has an unrelated separate gap"), json_result(false)]
      end)

      {_result2, state} = GoalVerifier.verify(state)
      refute GoalVerifier.stalled?(state)
    end
  end
end
