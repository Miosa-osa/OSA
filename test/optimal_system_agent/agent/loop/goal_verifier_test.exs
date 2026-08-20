defmodule OptimalSystemAgent.Agent.Loop.GoalVerifierTest do
  @moduledoc """
  P1: independent goal-level verifier — separate read-only skeptic panel,
  majority-refute vote, run cap, and stall early-exit.

  The subagent runner is stubbed via `:goal_verifier_panel_runner` so these
  are pure unit tests — no real Loop GenServer / LLM call is spawned.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger

  # The lifetime verification-round cap is OFF by default: counting rounds
  # punished thoroughness, and Codex bounds a goal by token budget and elapsed
  # time instead. These cases exercise the cap itself, so they ask for one -
  # which is what "opt-in" means.
  setup do
    previous = Application.fetch_env(:optimal_system_agent, :goal_tracker_max_runs)
    Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 12)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, v)
        :error -> Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
      end
    end)

    :ok
  end

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
    dir =
      Path.join(System.tmp_dir!(), "goal-verifier-clean-#{System.unique_integer([:positive])}")

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

  # ── TUI-facing labels ────────────────────────────────────────────────────

  describe "skeptic display labels" do
    # The roster read
    #   ├─ ○ goal-verifier-skeptic  You are an ADVERSARIAL, INDEPENDENT reviewer…
    # because the orchestrator falls back to the first 80 chars of `:task` when a
    # config carries no `:description` — and a skeptic's "task" IS its system
    # prompt. Each skeptic must name itself instead.
    test "every skeptic config carries a short human description, not its prompt",
         %{session_id: sid} do
      {configs, _result} = capture_prompts(sid, [false, false, false])

      for config <- configs do
        desc = config[:description]
        assert is_binary(desc) and desc != "", "skeptic config has no :description"
        assert String.length(desc) <= 40, "description is not a label: #{inspect(desc)}"
        assert desc =~ ~r/^skeptic #\d+ · \w+$/u, "unexpected label: #{inspect(desc)}"
        refute desc =~ "ADVERSARIAL", "prompt body leaked into the label"
      end

      # Each panel member is distinguishable in the roster.
      descs = Enum.map(configs, & &1[:description])
      assert length(Enum.uniq(descs)) == length(descs)
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
        [
          {:ok, "I looked around and it seems fine, no structured answer here."},
          json_result(false),
          json_result(false)
        ]
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
        [
          json_result(true, reason: "missing test coverage"),
          json_result(true, reason: "missing test coverage"),
          json_result(false)
        ]
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
        [
          json_result(true, reason: "gap A"),
          json_result(true, reason: "gap A"),
          json_result(false)
        ]
      end)

      {result1, state} = GoalVerifier.verify(state)
      assert result1.verdict == :incomplete
      refute GoalVerifier.stalled?(state)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, reason: "gap B (different)"),
          json_result(true, reason: "gap B (different)"),
          json_result(false)
        ]
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
        [
          json_result(true, reason: "still broken #{System.unique_integer()}"),
          json_result(true),
          json_result(false)
        ]
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

      stub_runner(fn _sid, _configs ->
        [json_result(false), json_result(false), json_result(false)]
      end)

      assert {:pass, _state} = GoalVerifier.check(base_state(sid))
    end

    test "returns {:gate, directive, state} on :incomplete with gap details inlined", %{
      session_id: sid
    } do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, reason: "missing edge-case handling"),
          json_result(true, reason: "no tests"),
          json_result(false)
        ]
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
        [
          json_result(true, reason: "lib/foo/bar.ex is missing the new function"),
          json_result(true, reason: "lib/foo/bar.ex is missing the new function"),
          json_result(false)
        ]
      end)

      {_result1, state} = GoalVerifier.verify(state)
      refute GoalVerifier.stalled?(state)

      stub_runner(fn _sid, _configs ->
        [
          json_result(true, reason: "lib/baz/qux.ex has an unrelated separate gap"),
          json_result(true, reason: "lib/baz/qux.ex has an unrelated separate gap"),
          json_result(false)
        ]
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
          json_result(true,
            reason: "lib/exporter.ex is missing error handling for the widget path"
          )
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

    test "an unparseable skeptic response never reaches the status-bar gap summary",
         %{session_id: sid} do
      capture_goal_verifier_events(sid)
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          {:ok, "I am afraid I cannot comply with that request."},
          {:ok, "<<<%%% garbage %%%>>>"},
          {:error, :timeout}
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      # Still fail-closed on the VOTE — nothing vouched for completion.
      assert result.verdict == :incomplete
      assert result.refuted_count == 3

      assert_receive {:goal_verifier_event, %{phase: :start}}, 2000
      assert_receive {:goal_verifier_event, %{phase: :done} = done}, 2000

      # …but the user-facing summary carries NO harness diagnostics.
      assert done.gaps == []

      refute Enum.any?(done.gaps, &String.contains?(&1, "unparsable"))
      refute Enum.any?(done.gaps, &String.contains?(&1, "skeptic failed"))
    end
  end

  # ── Lenient three-tier parsing ────────────────────────────────────────────

  describe "lenient skeptic-response parsing" do
    test "tier 1: a bare JSON verdict parses strictly", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          {:ok,
           ~s({"refuted": true, "off_track": false, "reason": "lib/exporter.ex emits CSV, goal asked for JSON"})},
          {:ok,
           ~s({"refuted": true, "off_track": false, "reason": "lib/exporter.ex emits CSV, goal asked for JSON"})},
          {:ok, ~s({"refuted": false, "off_track": false, "reason": "looks right"})}
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.refuted_count == 2
      assert Enum.any?(result.gaps, &String.contains?(&1, "goal asked for JSON"))
    end

    test "tier 2: JSON wrapped in prose and in a ```json fence parses via brace-slice",
         %{session_id: sid} do
      mark_write(sid)

      prose = """
      Let me think about this. I read lib/exporter.ex and the goal.

      {"refuted": true, "off_track": false, "reason": "the header row is dropped in lib/exporter.ex"}

      That is my verdict.
      """

      fenced = """
      ```json
      {"refuted": true, "off_track": false, "reason": "no test covers the empty-input path"}
      ```
      """

      stub_runner(fn _sid, _configs ->
        [
          {:ok, prose},
          {:ok, fenced},
          {:ok, ~s({"refuted": false, "off_track": false, "reason": "ok"})}
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.refuted_count == 2
      assert Enum.any?(result.gaps, &String.contains?(&1, "header row is dropped"))
      assert Enum.any?(result.gaps, &String.contains?(&1, "empty-input path"))
      # The raw fence/prose wrapper must NOT survive into the gap text.
      refute Enum.any?(result.gaps, &String.contains?(&1, "```"))
      refute Enum.any?(result.gaps, &String.contains?(&1, "Let me think"))
    end

    test "tier 2: a nested JSON object still parses (the old flat regex could not)",
         %{session_id: sid} do
      mark_write(sid)

      nested =
        ~s({"refuted": true, "off_track": false, "reason": "missing migration", "evidence": {"file": "lib/repo.ex", "line": 12}})

      stub_runner(fn _sid, _configs ->
        [
          {:ok, nested},
          {:ok, nested},
          {:ok, ~s({"refuted": false, "off_track": false, "reason": "ok"})}
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert Enum.any?(result.gaps, &String.contains?(&1, "missing migration"))
    end

    test "tier 2: a stringly-typed boolean is coerced rather than rejected",
         %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [
          {:ok,
           ~s({"refuted": "true", "off_track": "false", "reason": "the export step is stubbed"})},
          {:ok,
           ~s({"refuted": "yes", "off_track": "no", "reason": "the export step is stubbed"})},
          {:ok, ~s({"refuted": "false", "off_track": "false", "reason": "fine"})}
        ]
      end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.refuted_count == 2
      assert Enum.any?(result.gaps, &String.contains?(&1, "export step is stubbed"))
    end

    test "tier 3: pure garbage degrades to a low-confidence result, never an error",
         %{session_id: sid} do
      mark_write(sid)

      garbage = "!!! ###  %%%  \n\n  ??? "

      stub_runner(fn _sid, _configs -> [{:ok, garbage}, {:ok, garbage}, {:ok, garbage}] end)

      # The whole point: this must not raise, and must still produce a verdict.
      {result, state} = GoalVerifier.verify(base_state(sid))

      assert %GoalVerifier.Result{} = result
      assert result.verdict == :incomplete
      assert result.refuted_count == 3
      assert result.total == 3
      assert state.goal_verifier_runs == 1

      # The raw text is kept as information, honestly labelled — and the
      # fabricated "unparsable skeptic response (fail-closed)" string is gone.
      refute Enum.any?(result.gaps, &String.contains?(&1, "unparsable"))
      assert Enum.all?(result.gaps, &String.contains?(&1, "unstructured review"))
    end

    test "tier 3: an empty skeptic response is handled without raising", %{session_id: sid} do
      mark_write(sid)
      stub_runner(fn _sid, _configs -> [{:ok, ""}, {:ok, "   "}, {:ok, ""}] end)

      {result, _state} = GoalVerifier.verify(base_state(sid))

      assert result.verdict == :incomplete
      assert result.total == 3
      refute Enum.any?(result.gaps, &String.contains?(&1, "unparsable"))
    end

    test "harness diagnostics never become model-facing gaps either", %{session_id: sid} do
      mark_write(sid)

      stub_runner(fn _sid, _configs ->
        [{:error, :timeout}, {:error, {:crashed, :badarg}}, {:error, :timeout}]
      end)

      {result, state} = GoalVerifier.verify(base_state(sid))
      assert result.verdict == :incomplete
      assert result.gaps == []

      # With no actionable gap the directive falls back to the honest
      # "no structured findings" phrasing rather than echoing ":timeout".
      {directive, _state} = GoalVerifier.build_directive(result, state)
      refute directive.content =~ "timeout"
      refute directive.content =~ "skeptic failed"
      assert directive.content =~ "no structured findings"
    end
  end

  # ── Per-skeptic timeout bound ─────────────────────────────────────────────

  describe "skeptic timeout bound" do
    test "the panel is joined with the goal-verifier bound, not the 2h subagent backstop",
         %{session_id: sid} do
      mark_write(sid)
      Application.delete_env(:optimal_system_agent, :goal_verifier_panel_runner)

      timeout =
        Application.get_env(:optimal_system_agent, :goal_verifier_skeptic_timeout_ms, 120_000)

      generic =
        Application.get_env(:optimal_system_agent, :subagent_await_timeout_ms, 2 * 60 * 60 * 1000)

      assert is_integer(timeout)
      assert timeout > 0

      assert timeout < generic,
             "a read-only skeptic vote must be bounded far tighter than a delegated workstream"
    end
  end

  # ── Prompt output contract ────────────────────────────────────────────────

  describe "skeptic prompt output contract" do
    test "spells out a strict JSON shape with all three required fields", %{session_id: sid} do
      mark_write(sid)
      {configs, _result} = capture_prompts(sid, [false, false, false])

      task = hd(configs).task
      assert task =~ "Output contract"
      assert task =~ ~s("refuted")
      assert task =~ ~s("off_track")
      assert task =~ ~s("reason")
      assert task =~ "no markdown code fence"
      # Concrete examples make the shape far more reliably reproduced.
      assert task =~ ~s({"refuted": false, "off_track": false, "reason":)
    end
  end

  # ── Triage gate (grok goal_evaluator.rs parity) ──────────────────────────
  #
  # The expensive panel must be UNREACHABLE except through a cheap triage call
  # that returned `candidate_complete`. These tests assert the gate, not the
  # panel: the panel runner is stubbed to record whether it was reached at all.

  describe "triage gate" do
    setup %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      test_pid = self()

      stub_runner(fn _sid, configs ->
        send(test_pid, :panel_ran)
        Enum.map(configs, fn _ -> json_result(false) end)
      end)

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :goal_verifier_triage_runner)
        Application.delete_env(:optimal_system_agent, :goal_verifier_trivial_max_writes)
        Application.delete_env(:optimal_system_agent, :goal_verifier_trivial_max_iterations)
        Application.delete_env(:optimal_system_agent, :goal_verifier_blocker_streak_threshold)
        GoalTracker.reset(sid)
      end)

      :ok
    end

    defp stub_triage(fun),
      do: Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, fun)

    defp triage_json(status, opts \\ []) do
      key = Keyword.get(opts, :blocker_key, "")
      reason = Keyword.get(opts, :reason, "because")

      {:ok,
       ~s({"status": "#{status}", "reason": #{Jason.encode!(reason)}, "blocker_key": #{Jason.encode!(key)}})}
    end

    # A turn big enough that only the TRIAGE verdict decides the outcome:
    # anchored goal (so `trivial_turn?` is false), several distinct writes.
    defp complex_state(sid) do
      GoalTracker.start(sid, "ship the widget exporter end to end")
      mark_write(sid, "lib/widget/exporter.ex")
      mark_write(sid, "lib/widget/router.ex")
      mark_write(sid, "test/widget/exporter_test.exs")

      sid
      |> base_state()
      |> Map.put(:iteration, 8)
      |> Map.put(:working_dir, isolated_clean_repo())
    end

    test "a trivial turn (one write) never reaches triage OR the panel", %{session_id: sid} do
      GoalTracker.start(sid, "install the MCP server")
      mark_write(sid, ".osa/mcp.json")

      stub_triage(fn _state -> flunk("triage must not be called for a trivial turn") end)

      state =
        sid
        |> base_state()
        |> Map.put(:iteration, 6)
        |> Map.put(:working_dir, isolated_clean_repo())

      assert GoalVerifier.trivial_turn?(state)
      assert GoalVerifier.skip_reason(state) == :trivial

      out = GoalVerifier.maybe_gate(state)

      refute_received :panel_ran
      assert out.messages == state.messages, "a skipped boundary must inject no directive"
    end

    test "a one-round question turn is trivial by iteration count", %{session_id: sid} do
      GoalTracker.start(sid, "what does this module do?")
      mark_write(sid, "a.ex")
      mark_write(sid, "b.ex")
      mark_write(sid, "c.ex")

      state = sid |> base_state() |> Map.put(:iteration, 1)
      assert GoalVerifier.trivial_turn?(state)
      assert GoalVerifier.skip_reason(state) == :trivial
    end

    test "no goal anywhere skips before triage", %{session_id: sid} do
      mark_write(sid, "a.ex")
      mark_write(sid, "b.ex")
      mark_write(sid, "c.ex")

      state = sid |> base_state() |> Map.put(:iteration, 8)
      assert GoalVerifier.skip_reason(state) == :no_goal
    end

    test "a complex turn is NOT trivial and does reach triage", %{session_id: sid} do
      state = complex_state(sid)
      refute GoalVerifier.trivial_turn?(state)
      assert GoalVerifier.skip_reason(state) == nil
    end

    test "triage=continue stops before the panel", %{session_id: sid} do
      state = complex_state(sid)
      stub_triage(fn _ -> triage_json("continue") end)

      out = GoalVerifier.maybe_gate(state)

      refute_received :panel_ran
      assert out.messages == state.messages
      assert Map.get(out, :goal_verifier_runs, 0) == 0
    end

    test "triage=candidate_complete DOES run the panel", %{session_id: sid} do
      state = complex_state(sid)
      stub_triage(fn _ -> triage_json("candidate_complete") end)

      out = GoalVerifier.maybe_gate(state)

      assert_received :panel_ran
      assert out.goal_verifier_runs == 1
    end

    test "a refuting panel injects exactly one directive and does not re-enter", %{
      session_id: sid
    } do
      state = complex_state(sid)
      stub_triage(fn _ -> triage_json("candidate_complete") end)

      stub_runner(fn _sid, configs ->
        Enum.map(configs, fn _ ->
          json_result(true, reason: "lib/widget/exporter.ex writes CSV not JSON")
        end)
      end)

      out = GoalVerifier.maybe_gate(state)

      injected = out.messages -- state.messages
      assert length(injected) == 1
      assert hd(injected).role == "system"
      assert hd(injected).content =~ "GOAL VERIFIER"
    end

    # ── blocker_key streak ─────────────────────────────────────────────────

    test "the same blocker three rounds running auto-pauses", %{session_id: sid} do
      state = complex_state(sid)

      stub_triage(fn _ ->
        triage_json("blocked", blocker_key: "missing_api_key", reason: "no ANTHROPIC_API_KEY")
      end)

      s1 = GoalVerifier.maybe_gate(state)
      assert s1.goal_verifier_blocker_streak == 1
      refute s1.goal_verifier_paused
      assert s1.messages == state.messages

      s2 = GoalVerifier.maybe_gate(s1)
      assert s2.goal_verifier_blocker_streak == 2
      refute s2.goal_verifier_paused
      assert s2.messages == state.messages

      s3 = GoalVerifier.maybe_gate(s2)
      assert s3.goal_verifier_blocker_streak == 3
      assert s3.goal_verifier_paused
      pause = List.last(s3.messages)
      assert pause.content =~ "AUTO-PAUSE"
      assert pause.content =~ "missing_api_key"

      # And the latch holds: a further boundary is a no-op, not a second pause.
      s4 = GoalVerifier.maybe_gate(s3)
      assert s4.messages == s3.messages

      refute_received :panel_ran
    end

    test "a DIFFERENT blocker resets the streak", %{session_id: sid} do
      state = complex_state(sid)

      stub_triage(fn _ -> triage_json("blocked", blocker_key: "missing_api_key") end)
      s1 = GoalVerifier.maybe_gate(state)
      s2 = GoalVerifier.maybe_gate(s1)
      assert s2.goal_verifier_blocker_streak == 2

      stub_triage(fn _ -> triage_json("blocked", blocker_key: "port_in_use") end)
      s3 = GoalVerifier.maybe_gate(s2)
      assert s3.goal_verifier_blocker_streak == 1
      refute s3.goal_verifier_paused
    end

    test "blocker keys are normalized so rewording does not reset the streak", %{session_id: sid} do
      state = complex_state(sid)

      stub_triage(fn _ -> triage_json("blocked", blocker_key: "Missing API Key") end)
      s1 = GoalVerifier.maybe_gate(state)

      stub_triage(fn _ -> triage_json("blocked", blocker_key: "missing_api_key") end)
      s2 = GoalVerifier.maybe_gate(s1)

      assert s2.goal_verifier_blocker_streak == 2
    end

    test "a non-blocked triage clears an in-flight blocker streak", %{session_id: sid} do
      state = complex_state(sid)

      stub_triage(fn _ -> triage_json("blocked", blocker_key: "missing_api_key") end)
      s1 = GoalVerifier.maybe_gate(state)
      assert s1.goal_verifier_blocker_streak == 1

      stub_triage(fn _ -> triage_json("continue") end)
      s2 = GoalVerifier.maybe_gate(s1)
      assert s2.goal_verifier_blocker_streak == 0
      assert s2.goal_verifier_blocker_key == nil
    end

    # ── Triage failure — FAIL-OPEN (defer), never fail-closed (panel) ───────
    #
    # A triage that cannot run means the provider that just drove the turn is
    # unhealthy — every skeptic would fail too, and a panel of failures is a
    # synthetic majority-refute: an `:incomplete` gate that loops the agent at
    # 3x the cost for zero information. So the gate DEFERS. It never asserts
    # completion (GoalTracker is untouched, so `reverify_due?/1` fires again at
    # the next boundary) and the panel's own fail-closed vote is unchanged
    # wherever the panel actually runs.

    test "a triage error skips the panel rather than running it", %{session_id: sid} do
      state = complex_state(sid)
      stub_triage(fn _ -> {:error, :provider_down} end)

      out = GoalVerifier.maybe_gate(state)

      refute_received :panel_ran
      assert out.messages == state.messages
      assert Map.get(out, :goal_verifier_runs, 0) == 0
    end

    test "a triage that raises is caught and skips", %{session_id: sid} do
      state = complex_state(sid)
      stub_triage(fn _ -> raise "boom" end)

      assert GoalVerifier.maybe_gate(state).messages == state.messages
      refute_received :panel_ran
    end

    test "a triage that hangs is bounded and skips", %{session_id: sid} do
      state = complex_state(sid)
      Application.put_env(:optimal_system_agent, :goal_verifier_triage_timeout_ms, 80)

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :goal_verifier_triage_timeout_ms)
      end)

      stub_triage(fn _ -> Process.sleep(5_000) end)

      assert GoalVerifier.maybe_gate(state).messages == state.messages
      refute_received :panel_ran
    end

    test "unparsable triage output skips rather than guessing candidate_complete", %{
      session_id: sid
    } do
      state = complex_state(sid)
      stub_triage(fn _ -> {:ok, "I'm sorry, I can't help with that."} end)

      assert GoalVerifier.maybe_gate(state).messages == state.messages
      refute_received :panel_ran
    end

    test "triage output wrapped in prose/fences is still read", %{session_id: sid} do
      state = complex_state(sid)

      stub_triage(fn _ ->
        {:ok,
         "Here you go:\n```json\n{\"status\":\"candidate_complete\",\"reason\":\"looks done\",\"blocker_key\":\"\"}\n```\nHope that helps."}
      end)

      GoalVerifier.maybe_gate(state)
      assert_received :panel_ran
    end

    # ── Cost shape ─────────────────────────────────────────────────────────

    test "the triage prompt is compact and carries no diff", %{session_id: sid} do
      state = complex_state(sid)
      messages = GoalVerifier.triage_messages(state)

      text = Enum.map_join(messages, "\n", & &1.content)

      # The panel gets the diff; triage must not — that is the cost difference.
      refute text =~ "```diff"
      refute text =~ "Accumulated diff"

      assert text =~ "candidate_complete"
      assert text =~ "blocker_key"
      assert text =~ "## Goal"

      # Hard cost ceiling. The skeptic panel's prompts run ~850 tokens EACH
      # (×3 subagent sessions); triage must stay an order of magnitude below one
      # of them or it is just a second tax.
      assert div(byte_size(text), 4) < 1_200,
             "triage prompt is #{div(byte_size(text), 4)} est. tokens — no longer cheap"
    end
  end
end
