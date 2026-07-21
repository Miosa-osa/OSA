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
      Application.delete_env(:optimal_system_agent, :goal_verifier_enabled)
      Application.delete_env(:optimal_system_agent, :goal_verifier_activate_after_iterations)
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

  # Run a verify/1 round against an isolated clean repo, capturing the exact
  # skeptic configs (prompts + assigned lenses) the panel was built with.
  defp capture_prompts(sid, refuted_list) do
    test_pid = self()

    stub_runner(fn _sid, configs ->
      send(test_pid, {:configs, configs})
      Enum.map(refuted_list, &json_result/1)
    end)

    state = base_state(sid) |> Map.put(:working_dir, isolated_clean_repo())
    {result, _state} = GoalVerifier.verify(state)

    assert_received {:configs, configs}
    {configs, result}
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

  # ── Smart activation (task 1) ───────────────────────────────────────────
  # Resolution precedence: explicit config wins; otherwise :auto turns the
  # panel ON for autonomous/long-running work and OFF for short interactive
  # turns.

  describe "activated?/1 smart activation" do
    test "OFF for a short interactive ask-mode turn under :auto", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      refute GoalVerifier.activated?(%{})
      refute GoalVerifier.activated?(%{session_id: sid, iteration: 2, permission_mode: :ask})
    end

    test "ON under overdrive on the live state under :auto", %{session_id: _sid} do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      assert GoalVerifier.activated?(%{permission_mode: :overdrive})
      assert GoalVerifier.activated?(%{permission_mode: :bypass})
    end

    test "ON once a turn passes the activation iteration threshold, even in ask mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      Application.put_env(:optimal_system_agent, :goal_verifier_activate_after_iterations, 12)

      refute GoalVerifier.activated?(%{iteration: 11, permission_mode: :ask})
      assert GoalVerifier.activated?(%{iteration: 12, permission_mode: :ask})
    end

    test "explicit config override wins both ways" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
      # forced OFF even under overdrive
      refute GoalVerifier.activated?(%{permission_mode: :overdrive})

      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      # forced ON even for a bare short turn
      assert GoalVerifier.activated?(%{})
    end
  end

  # ── Perspective-diverse skeptics (task 3) ───────────────────────────────
  # grok runs N IDENTICAL skeptics; OSA gives each a DISTINCT lens
  # (correctness / completeness / verifiability). The set is data-driven and
  # scales gracefully when skeptic_count != 3.

  describe "perspective-diverse skeptic lenses" do
    test "the 3-skeptic panel assigns 3 DISTINCT lenses, one prompt each", %{session_id: sid} do
      mark_write(sid)
      {configs, _result} = capture_prompts(sid, [false, false, false])

      assert length(configs) == 3
      titles = Enum.map(configs, & &1.task)

      assert Enum.any?(titles, &(&1 =~ "CORRECTNESS lens"))
      assert Enum.any?(titles, &(&1 =~ "COMPLETENESS lens"))
      assert Enum.any?(titles, &(&1 =~ "VERIFIABILITY lens"))

      # Distinct focus text — not the same prompt N times (the grok weakness).
      assert configs |> Enum.map(& &1.task) |> Enum.uniq() |> length() == 3

      # Every lens keeps the anti-over-refusal contract.
      for %{task: prompt} <- configs do
        assert prompt =~ "Default to NOT-REFUTED when uncertain"
        assert prompt =~ "CONCRETE evidence"
      end

      # Lens tag threaded onto the subagent name for observability.
      lens_keys = configs |> Enum.map(& &1.lens) |> Enum.sort()
      assert lens_keys == [:completeness, :correctness, :verifiability]
    end

    test "scales gracefully to 5 skeptics by cycling the lens set", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_skeptic_count, 5)

      {configs, _result} = capture_prompts(sid, [false, false, false, false, false])

      assert length(configs) == 5
      # 5 = ceil over 3 lenses -> correctness x2, completeness x2, verifiability x1
      counts = configs |> Enum.frequencies_by(& &1.lens)
      assert counts[:correctness] == 2
      assert counts[:completeness] == 2
      assert counts[:verifiability] == 1
    end

    test "scales down to a single correctness skeptic", %{session_id: sid} do
      mark_write(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_skeptic_count, 1)

      {configs, _result} = capture_prompts(sid, [false])

      assert [%{lens: :correctness, task: prompt}] = configs
      assert prompt =~ "CORRECTNESS lens"
    end
  end

  # ── End-to-end: pass a finished goal, refute an unfinished one ───────────

  describe "finished goal passes; unfinished goal refutes with lens-tagged gap feedback" do
    test "a FINISHED goal (all three lenses not-refuted) -> :complete -> {:pass}", %{
      session_id: sid
    } do
      mark_write(sid)

      # correctness / completeness / verifiability all agree the goal is met.
      stub_runner(fn _sid, configs ->
        assert length(configs) == 3
        [json_result(false), json_result(false), json_result(false)]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))
      assert result.verdict == :complete

      # The loop is allowed to finish (no false block).
      assert {:pass, _state} = GoalVerifier.check(base_state(sid))
    end

    test "an UNFINISHED goal (completeness + verifiability refute) -> :incomplete with lens-tagged gaps fed back",
         %{session_id: sid} do
      mark_write(sid)

      # correctness passes, but completeness and verifiability each find a
      # concrete gap -> majority-refute -> :incomplete.
      stub_runner(fn _sid, configs ->
        # lenses are assigned in order: correctness, completeness, verifiability
        assert Enum.map(configs, & &1.lens) == [:correctness, :completeness, :verifiability]

        [
          json_result(false, reason: "behavior is correct for the happy path"),
          json_result(true, reason: "the CSV export path in lib/exporter.ex is only a stub"),
          json_result(true, reason: "no test proves lib/exporter.ex actually runs")
        ]
      end)

      {:gate, directive, state} = GoalVerifier.check(base_state(sid))

      assert directive.role == "system"
      # gaps fed back to the SAME agent as a concrete, actionable nudge.
      assert directive.content =~ "NOT DONE"
      assert directive.content =~ "address these specific gaps"
      # each gap is attributed to the lens that caught it.
      assert directive.content =~ "[completeness]"
      assert directive.content =~ "[verifiability]"
      assert directive.content =~ "lib/exporter.ex is only a stub"
      assert state.goal_verifier_prompts == 1
    end

    test "a malformed verdict still counts as a refute (fail-closed) in a diverse panel", %{
      session_id: sid
    } do
      mark_write(sid)

      # correctness malformed (fail-closed refute) + completeness refute ->
      # 2/3 refute -> majority -> :incomplete.
      stub_runner(fn _sid, _configs ->
        [
          {:ok, "no structured verdict here at all"},
          json_result(true, reason: "missing requirement in lib/exporter.ex"),
          json_result(false)
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))
      assert result.verdict == :incomplete
      assert result.refuted_count == 2
    end
  end

  describe "TUI event surfacing (goal_verifier_round emit)" do
    # Capture the raw `:system_event` payloads this module emits on the Bus, so
    # we can assert on the exact fields the TUI indicator consumes without
    # spinning up the full forwarder/PubSub path.
    # Filter on the test's OWN session_id. The Bus dispatches handlers via
    # asynchronous supervised Tasks, so a `goal_verifier_round` event emitted by
    # a PRIOR test's verify/1 can still be in-flight when this test registers its
    # handler — without the session guard that stale event (a different verdict,
    # e.g. :off_track) races into our mailbox and flakes the assert_receive.
    defp capture_goal_verifier_events(sid) do
      test_pid = self()

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          data =
            case payload do
              %{data: d} when is_map(d) -> d
              d when is_map(d) -> d
            end

          if data[:event] == :goal_verifier_round and data[:session_id] == sid do
            send(test_pid, {:goal_verifier_event, data})
          end
        end)

      on_exit(fn -> OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref) end)
      ref
    end

    test "emits a start-phase signal then a done-phase verdict with compact gaps",
         %{session_id: sid} do
      capture_goal_verifier_events(sid)
      mark_write(sid)

      stub_runner(fn _sid, configs ->
        # All refute with a lens-tagged, concrete gap -> :incomplete with gaps.
        Enum.map(configs, fn _ ->
          json_result(true, reason: "lib/exporter.ex is missing error handling for the widget path")
        end)
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))
      assert result.verdict == :incomplete

      # 1) The lightweight "verifying…" start signal is emitted first.
      assert_receive {:goal_verifier_event, %{phase: :start, round: 1}}, 2000

      # 2) The done event carries the verdict plus a COMPACT, lens-tagged gap
      #    summary (a small list of strings) for the status indicator.
      assert_receive {:goal_verifier_event, done}, 2000
      assert done.phase == :done
      assert done.verdict == :incomplete
      assert done.refuted_count == 3
      assert done.total == 3
      assert is_list(done.gaps) and done.gaps != []
      # Kept small (at most the first two findings), each already lens-tagged.
      assert length(done.gaps) <= 2
      assert Enum.all?(done.gaps, &is_binary/1)
      assert Enum.any?(done.gaps, &String.contains?(&1, "[completeness]"))
    end

    test "a complete verdict emits an empty gap summary", %{session_id: sid} do
      capture_goal_verifier_events(sid)
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [json_result(false), json_result(false), json_result(false)]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))
      assert result.verdict == :complete

      assert_receive {:goal_verifier_event, %{phase: :start}}, 2000
      assert_receive {:goal_verifier_event, %{phase: :done, verdict: :complete, gaps: []}}, 2000
    end
  end
end
