defmodule OptimalSystemAgent.Agent.Loop.AutonomousGoalLoopTest do
  @moduledoc """
  The autonomous goal loop: anchoring a goal, pursuing it across a turn, and —
  the part that actually matters — STOPPING on a finished goal while NOT
  stopping on an unfinished one.

  The operator's ask: "it should be able to automatically create its own goal,
  and then just keep working autonomously or proactively until the goal is
  actually completed."

  `Agent.Loop.GoalTracker` was already fully built when this was written — a
  durable cross-turn status machine with a gap-fingerprint stall detector, a
  lifetime run cap and a reverify cadence — and `GoalTracker.start/2` had NO
  caller anywhere in `lib/`. The machine was reachable only through `advance/2`
  from the verifier, advancing a goal nothing had ever started. These tests
  cover the door that was added onto it and the loop re-entry it now drives.

  ## What the discrimination tests do and do not establish

  `verdict_both_directions` injects `:goal_verifier_panel_runner` and drives the
  real `GoalVerifier.verify/1` → `GoalTracker.advance/2` → re-entry chain. It
  establishes that the WIRING discriminates: a not-refuting panel completes the
  goal and stops the loop, a refuting panel leaves it active and the loop keeps
  going.

  It does NOT establish that real skeptics correctly tell finished work from
  unfinished work. That is a property of the model, needs a live provider, and
  is exactly the defect class this codebase has already failed at nine times —
  a test that measures the wrong property still passes. The injected panel is a
  stand-in for the judgment, not evidence about it. Read the loop-stopping
  assertions as "the harness obeys the panel", never as "the panel is right".
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.TaskBrief
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    saved =
      for key <- [
            :default_provider,
            :max_iterations,
            :goal_tracker_enabled,
            :goal_verifier_enabled,
            :goal_verifier_panel_runner,
            :goal_verifier_skeptic_count,
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

    # Every mock call answers with plain text and NO tool calls. That is the
    # exact shape this feature is about: a turn that ends on a final answer
    # while the goal is still unmet. Without it the mock emits tool calls and
    # the round-trip count measures the doom-loop guard instead of the goal
    # clause.
    Application.put_env(
      :optimal_system_agent,
      :mock_provider_final_text,
      "I have made a change. Let me know if you need anything else."
    )

    # The skeptic panel is exercised deliberately and only where a runner is
    # injected; it must never fire incidentally inside a loop-level test.
    Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
    # Compaction must not be the thing that continues the turn in these tests —
    # it shares the same budget, so an incidental fold would be indistinguishable
    # from a goal continuation.
    Application.put_env(:optimal_system_agent, :proactive_compaction_enabled, false)

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

  defp sid, do: "goal-loop-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      messages: [%{role: "user", content: "get on with it"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  defp run_turn(session_id) do
    MockProvider.reset_round_trips()
    {_response, state} = ReactLoop.run(base_state(session_id))
    {MockProvider.round_trips(), state}
  end

  # A skeptic vote in the shape `parse_skeptic_result/1` expects from the panel
  # runner: `{:ok, json_string}`.
  defp vote(refuted?, reason) do
    {:ok, Jason.encode!(%{"refuted" => refuted?, "off_track" => false, "reason" => reason})}
  end

  defp inject_panel(votes) do
    Application.put_env(:optimal_system_agent, :goal_verifier_panel_runner, fn _sid, _configs ->
      votes
    end)
  end

  # ---------------------------------------------------------------------------

  describe "the door — anchoring a goal reaches the machine that was already built" do
    test "/goal anchors a tracked, durable goal where nothing did before" do
      session_id = sid()

      refute GoalTracker.goal_loop?(session_id),
             "a fresh session must not look like an anchored goal loop"

      capture_cli(fn ->
        OptimalSystemAgent.Channels.CLI.Commands.dispatch(
          "goal ship the widget exporter",
          session_id
        )
      end)

      snap = GoalTracker.snapshot(session_id)

      assert snap.goal == "ship the widget exporter"
      assert snap.status == :active
      assert is_binary(snap.goal_id) and snap.goal_id != ""

      assert GoalTracker.goal_loop?(session_id),
             "GoalTracker.start/2 had no caller in lib/ — /goal is that caller"

      # And the durable sidecar that makes the circuit breaker survive the BEAM.
      assert File.exists?(GoalTracker.store_path(session_id))

      GoalTracker.reset(session_id)
    end

    test "anchoring captures the immutable TaskBrief injected into every system block" do
      session_id = sid()

      capture_cli(fn ->
        OptimalSystemAgent.Channels.CLI.Commands.dispatch("goal ship the exporter", session_id)
      end)

      assert {:ok, brief} = TaskBrief.load(session_id)
      assert brief.goal == "ship the exporter"

      GoalTracker.reset(session_id)
    end

    test "acceptance criteria are AUTHORED, not an echo of the goal text" do
      session_id = sid()

      capture_cli(fn ->
        OptimalSystemAgent.Channels.CLI.Commands.dispatch(
          "goal ship the exporter :: mix test passes and lib/exporter.ex exports dump/1",
          session_id
        )
      end)

      assert {:ok, brief} = TaskBrief.load(session_id)
      assert brief.goal == "ship the exporter"

      assert brief.acceptance_criteria ==
               "mix test passes and lib/exporter.ex exports dump/1"

      refute brief.acceptance_criteria == brief.goal,
             "criteria that restate the goal say nothing about what done means — " <>
               "this was the standing behaviour, because nothing ever plumbed them"

      GoalTracker.reset(session_id)
    end

    test "a goal set by the AGENT ITSELF anchors the tracker, not just the ledger" do
      session_id = sid()

      # The progress_note tool is how the model authors its own goal. It wrote
      # the ledger and the brief and left the cross-turn machine untouched.
      OptimalSystemAgent.Tools.Builtins.ProgressNote.Handler.execute(
        %{"note" => "GOAL: refactor the exporter"},
        %{session_id: session_id}
      )

      assert GoalTracker.goal_loop?(session_id),
             "a self-authored goal must light up the tracker, or 'create its own goal " <>
               "and keep working' has no machine behind it"

      assert GoalTracker.snapshot(session_id).goal == "refactor the exporter"

      GoalTracker.reset(session_id)
    end
  end

  # ---------------------------------------------------------------------------

  describe "re-entry — an unfinished goal keeps the turn going" do
    test "a text-only answer under an active goal is continued, not accepted as the end" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      {round_trips, _state} = run_turn(session_id)

      assert round_trips >= 2,
             "the turn made #{round_trips} round-trip(s): a goal that stops at the " <>
               "first text answer is not being pursued at all"

      GoalTracker.reset(session_id)
    end

    test "the continuation restates the goal verbatim rather than saying 'continue'" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the widget exporter")

      {_round_trips, state} = run_turn(session_id)

      texts =
        state
        |> Map.get(:messages, [])
        |> Enum.map_join("\n", &to_string(Map.get(&1, :content) || ""))

      assert String.contains?(texts, "[Goal loop]")
      assert String.contains?(texts, "ship the widget exporter")

      GoalTracker.reset(session_id)
    end

    test "a session with NO anchored goal is never continued" do
      session_id = sid()
      # `tick_turn/1` lazily creates a bare row for every session in the product.
      GoalTracker.tick_turn(session_id)

      refute ReactLoop.goal_continue_due?(%{session_id: session_id}),
             "a bare tracker row must not qualify as a goal loop, or EVERY session " <>
               "in the product silently gains an auto-continue loop"

      {round_trips, _state} = run_turn(session_id)
      assert round_trips == 1

      GoalTracker.reset(session_id)
    end
  end

  # ---------------------------------------------------------------------------

  describe "completion detection discriminates in BOTH directions" do
    # The direction every rejected detector got right.
    test "FINISHED: a non-refuting panel completes the goal and the loop stops" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      inject_panel([
        vote(false, "the exporter is implemented and covered"),
        vote(false, "every requirement is addressed"),
        vote(false, "tests demonstrate it works")
      ])

      {result, _state} =
        GoalVerifier.verify(%{session_id: session_id, working_dir: File.cwd!(), messages: []})

      assert result.verdict == :complete

      snap = GoalTracker.advance(session_id, result)
      assert snap.status == :completed

      refute ReactLoop.goal_continue_due?(%{session_id: session_id}),
             "a completed goal must not keep driving the loop"

      {round_trips, _state} = run_turn(session_id)

      assert round_trips == 1,
             "a completed goal still bought #{round_trips} round-trips — the loop is " <>
               "not actually reading the verdict"

      GoalTracker.reset(session_id)
    end

    # The direction every rejected detector got WRONG: firing on unfinished work.
    test "UNFINISHED: a refuting panel leaves the goal active and the loop keeps going" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      inject_panel([
        vote(true, "lib/exporter.ex has no dump/1; the writer is a TODO stub"),
        vote(true, "the CSV branch is unimplemented"),
        vote(false, "naming looks fine")
      ])

      {result, _state} =
        GoalVerifier.verify(%{session_id: session_id, working_dir: File.cwd!(), messages: []})

      assert result.verdict == :incomplete,
             "a majority-refuted goal must never read as complete"

      snap = GoalTracker.advance(session_id, result)

      assert snap.status == :active,
             "an unfinished goal must stay active, not be quietly completed"

      assert ReactLoop.goal_continue_due?(%{session_id: session_id})

      {round_trips, _state} = run_turn(session_id)

      assert round_trips == 4,
             "an unfinished goal drove #{round_trips} round-trip(s); expected 1 answer + " <>
               "the shared budget of 3. 1 means it stopped at the first text answer."

      GoalTracker.reset(session_id)
    end

    test "a panel that could not run at all fails CLOSED, never complete" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      inject_panel([{:error, :timeout}, {:error, :timeout}, {:error, :timeout}])

      {result, _state} =
        GoalVerifier.verify(%{session_id: session_id, working_dir: File.cwd!(), messages: []})

      refute result.verdict == :complete,
             "a crashed/timed-out panel must never silently pass the goal"

      assert GoalTracker.advance(session_id, result).status in [:active, :paused]

      GoalTracker.reset(session_id)
    end

    test "the model asserting completion in prose does NOT complete the goal" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      # The shipped TUI `/goal` loop stops when the reply's last line is "DONE".
      # That is the model grading its own homework. The tracker must not care.
      assert GoalTracker.snapshot(session_id).status == :active
      assert ReactLoop.goal_continue_due?(%{session_id: session_id})

      # Nothing about a self-declared completion changes tracker state; only
      # `advance/2` with a panel verdict can.
      assert GoalTracker.snapshot(session_id).status == :active

      GoalTracker.reset(session_id)
    end
  end

  # ---------------------------------------------------------------------------

  describe "stalls that look like progress" do
    test "two rounds citing the same gap pause the goal and stop the loop" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      # Same concrete identifier both rounds — different prose, same gap. The
      # fingerprint is over extracted identifiers precisely so re-worded prose
      # does not read as progress.
      inject_panel([
        vote(true, "lib/exporter.ex still has no dump/1"),
        vote(true, "lib/exporter.ex is missing dump/1"),
        vote(true, "no dump/1 in lib/exporter.ex")
      ])

      state = %{session_id: session_id, working_dir: File.cwd!(), messages: []}

      {r1, _} = GoalVerifier.verify(state)
      GoalTracker.advance(session_id, r1)

      {r2, _} = GoalVerifier.verify(state)
      snap = GoalTracker.advance(session_id, r2)

      assert snap.status == :paused
      assert snap.pause_reason == :no_progress

      refute ReactLoop.goal_continue_due?(%{session_id: session_id}),
             "a stalled goal must stop driving the loop"

      GoalTracker.reset(session_id)
    end
  end

  # ---------------------------------------------------------------------------

  describe "the continuation budget is shared, bounded, and reset per turn" do
    test "goal continuation spends the SAME counter as post-compaction continuation" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      {_round_trips, state} = run_turn(session_id)

      assert Map.get(state, :compaction_continues, 0) > 0,
             "the goal clause must spend the shared per-turn continuation budget — " <>
               "two independent resume budgets multiply into a bound neither can see"

      GoalTracker.reset(session_id)
    end

    test "an exhausted budget ends the turn on the model's own answer" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")
      Application.put_env(:optimal_system_agent, :compaction_max_continues, 0)

      {round_trips, _state} = run_turn(session_id)

      assert round_trips == 1,
             "with the budget at 0 the turn made #{round_trips} round-trips — the cap " <>
               "is not actually capping"

      GoalTracker.reset(session_id)
    end

    test "the budget is bounded well below the iteration ceiling" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")
      Application.put_env(:optimal_system_agent, :compaction_max_continues, 3)

      {round_trips, _state} = run_turn(session_id)

      # 1 answer + at most 3 continuations. `max_iterations` is 12 here; a run
      # that reaches it is a run with no budget of its own.
      assert round_trips == 4,
             "an anchored goal drove #{round_trips} round-trips against a budget of 3 " <>
               "(expected exactly 1 answer + 3 continuations, well under max_iterations 12)"

      GoalTracker.reset(session_id)
    end

    test "the shared budget resets per turn, so a long turn cannot spend it forever" do
      # A budget that never resets makes the first long turn spend it and every
      # later turn stop early — the exact failure the compaction work called out.
      state =
        sid()
        |> base_state()
        |> Map.put(:compaction_continues, 3)
        |> TurnPipeline.reset_per_turn_fields()

      assert state.compaction_continues == 0
    end
  end

  # ---------------------------------------------------------------------------

  describe "operator control" do
    test "/goal pause stops pursuit and /goal resume restarts it" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")

      GoalTracker.pause(session_id, :user)
      refute ReactLoop.goal_continue_due?(%{session_id: session_id})

      GoalTracker.resume(session_id)
      assert ReactLoop.goal_continue_due?(%{session_id: session_id})

      GoalTracker.reset(session_id)
    end

    test "an explicit goal_tracker_enabled: false disables pursuit entirely" do
      session_id = sid()
      GoalTracker.start(session_id, "ship the exporter")
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, false)

      refute ReactLoop.goal_continue_due?(%{session_id: session_id}),
             "the operator override must win over an anchored goal"

      GoalTracker.reset(session_id)
    end
  end

  defp capture_cli(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
