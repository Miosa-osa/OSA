defmodule OptimalSystemAgent.Agent.Loop.CompactionIsAContinuationTest do
  @moduledoc """
  Compaction is a continuation, not a boundary.

  The requirement, in the operator's words: "it compacts automatically, and then
  it continues where it left off and continues working, it doesn't just stop."

  These tests drive `ReactLoop.run/1` end to end against `MockProvider` with a
  history already over `CompactionThresholds.compact_at/1`, and count real
  provider round-trips. They establish three separate facts:

    1. the turn SURVIVES the fold (there is at least one model call after it);
    2. the rebuilt history carries a handoff note — the compact boundary, the
       working-context restore, and the still-in-flight reminder;
    3. the compaction→continue cycle is CAPPED, and an exhausted cap ends the
       turn cleanly rather than running to the global iteration ceiling.

  Round-trips here count the MAIN loop's calls only: `Compactor.bounded_chat/2`
  runs the summarizer inside a supervised task, and `MockProvider` keeps its
  counter in the calling process's dictionary. So "2 round-trips" means the
  model answered once and then answered again after the fold.

  `MockProvider` reports no `:usage`, which is not an artefact of the test: real
  providers do this too (`Providers.Cohere`, `Providers.Replicate`, several
  OpenAI-compat/local servers). `Accounting.maybe_put_last_input/2` only writes
  `last_input_tokens` when the provider reported a positive number, so on those
  providers the pre-compaction occupancy figure is never refreshed by a
  round-trip. That is what makes fact 3 reachable at all: without a refresh at
  the fold itself, `should_compact?/2` re-answers "yes" on every iteration and
  the loop pays for a summarizer round-trip each time.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Test.MockProvider

  # A summary the quality gate accepts: over @min_summary_length (200) and
  # carrying all three required section headers.
  @summary """
  1. Primary Request and Intent: the user asked for the retry budget to be made
     configurable and wired through the loop.
  2. Key Technical Concepts: exponential backoff, per-provider budgets.
  3. Files and Code Sections: lib/optimal_system_agent/providers/resilience.ex
  4. Errors and fixes: none outstanding.
  5. Problem Solving: the budget was hardcoded; it now reads app env.
  6. All user messages: "make the retry budget configurable".
  7. Pending Tasks: wire the new setting into the settings schema.
  8. Current Work: editing resilience.ex to read the configured budget.
  9. Optional Next Step: add the schema entry and run the test.
  """

  setup do
    saved =
      for key <- [
            :default_provider,
            :max_iterations,
            :mock_provider_final_text,
            :proactive_compaction_enabled,
            :proactive_compaction_auto_continue,
            :compaction_max_continues
          ],
          into: %{},
          do: {key, Application.fetch_env(:optimal_system_agent, key)}

    prev_env = System.get_env("OSA_DEFAULT_PROVIDER")
    System.put_env("OSA_DEFAULT_PROVIDER", "mock")

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, @summary)
    # A low ceiling so an unbounded compact→continue cycle terminates in bounded
    # test time. The measured number is still honest: a run that reaches this is
    # a run with no cap of its own.
    Application.put_env(:optimal_system_agent, :max_iterations, 10)

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

  defp sid, do: "compaction-continuation-#{System.unique_integer([:positive])}"

  # `compact_at` for an UNKNOWN window (which is what the mock model resolves
  # to) is computed off `CompactionThresholds.fallback_window/0`.
  defp over_threshold do
    CompactionThresholds.compact_at(CompactionThresholds.fallback_window()) + 10_000
  end

  # Enough turns that `split_turns/2` (keep 4) leaves a foldable older half, and
  # enough text in it to clear @default_min_older_tokens (400).
  defp long_history do
    filler = String.duplicate("the quick brown fox jumped over the lazy dog. ", 40)

    Enum.flat_map(1..8, fn i ->
      [
        %{role: "user", content: "step #{i}: #{filler}"},
        %{role: "assistant", content: "acknowledged #{i}: #{filler}"}
      ]
    end)
  end

  defp base_state(session_id) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      messages: long_history(),
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!(),
      last_input_tokens: over_threshold()
    })
  end

  defp run_turn(session_id \\ nil) do
    session_id = session_id || sid()
    MockProvider.reset_round_trips()
    {_response, state} = ReactLoop.run(base_state(session_id))
    {MockProvider.round_trips(), state}
  end

  describe "the turn survives the fold" do
    test "a mid-turn compaction is followed by more model work, not a stop" do
      {round_trips, state} = run_turn()

      # Two main-loop calls: the answer, and then the continuation after the
      # fold. One means the compaction ended the turn.
      assert round_trips >= 2,
             "the turn made #{round_trips} round-trip(s) — a compaction that ends the " <>
               "turn is exactly the stop the operator reported"

      assert is_map(state)
    end

    test "the folded history leads with a compact boundary the model can read" do
      {_round_trips, state} = run_turn()

      texts =
        state
        |> Map.get(:messages, [])
        |> Enum.map(&to_string(Map.get(&1, :content) || ""))

      assert Enum.any?(texts, &String.contains?(&1, "[Compact boundary]")),
             "nothing in the rebuilt history tells the model a compaction happened"

      assert Enum.any?(texts, &String.contains?(&1, "Post-compaction context restore")),
             "the working-context restore did not survive into the rebuilt history"
    end
  end

  describe "in-flight state survives the fold" do
    test "the still-active reminder is re-injected by the mid-turn path" do
      session_id = sid()

      OptimalSystemAgent.Agent.Tasks.add_task(session_id, "wire the schema entry", %{})
      OptimalSystemAgent.Agent.Tasks.add_task(session_id, "run the full suite", %{})

      {_round_trips, state} = run_turn(session_id)

      texts =
        state
        |> Map.get(:messages, [])
        |> Enum.map(&to_string(Map.get(&1, :content) || ""))
        |> Enum.join("\n")

      assert String.contains?(texts, "wire the schema entry"),
             "the open plan did not survive the fold — the cheapest possible " <>
               "statement of where the agent was, dropped"

      assert String.contains?(texts, "## TODO List"),
             "`CompactionSafety.build_reminder_message/1` was appended by the compactor " <>
               "pipeline but never by the mid-turn threshold fold — the one that runs " <>
               "during long autonomous work"

      assert String.contains?(texts, "still open on your plan"),
             "the continuation turn asked the model to continue without saying what " <>
               "it was in the middle of"
    end

    test "the restore block names the tasks instead of printing question marks" do
      session_id = sid()
      OptimalSystemAgent.Agent.Tasks.add_task(session_id, "wire the schema entry", %{})

      {_round_trips, state} = run_turn(session_id)

      texts =
        state
        |> Map.get(:messages, [])
        |> Enum.map(&to_string(Map.get(&1, :content) || ""))
        |> Enum.join("\n")

      # `CompactRestore.tasks_section/1` read `:subject`; `Agent.Tasks.get_tasks/1`
      # returns `%Tracker.Task{}` structs whose name field is `:title`. Every task
      # rendered as "- [ ] ?" — a checklist that survived the fold and said nothing.
      refute String.contains?(texts, "- [ ] ?"),
             "the restored checklist is a column of question marks"

      assert String.contains?(texts, "## Active Tasks\n- [ ] wire the schema entry")
    end
  end

  describe "the continuation is bounded" do
    test "a session that stays over threshold does not run to the iteration cap" do
      Application.put_env(:optimal_system_agent, :max_iterations, 10)

      {round_trips, _state} = run_turn()

      # Uncapped, every iteration paid a summarizer call plus a main call, so the
      # turn ran to the ceiling (measured: 11 main calls against a cap of
      # 10). The bound is `refresh_tokens_after_fold/2` — without it the
      # threshold check re-answers "yes" forever on a provider that reports no
      # usage.
      assert round_trips < 10,
             "the compact→continue cycle cost #{round_trips} round-trips against an " <>
               "iteration cap of 10 — it is bounded only by the global ceiling"
    end

    test "the fold, the answer, and one continuation — and then the turn ends" do
      {round_trips, _state} = run_turn()

      assert round_trips == 2,
             "expected 1 answer + exactly 1 post-compaction continuation, " <>
               "got #{round_trips} round-trips"
    end

    test "an exhausted budget ends the turn instead of continuing it again" do
      Application.put_env(:optimal_system_agent, :compaction_max_continues, 0)

      {round_trips, _state} = run_turn()

      assert round_trips == 1,
             "with no continuation budget the turn must end on the model's own answer; " <>
               "got #{round_trips} round-trips"
    end

    test "the budget is per turn, not per session" do
      # `reset_per_turn_fields/1` owns this. A counter that is not reset makes
      # the first long turn spend the budget and every later turn stop dead at
      # its first fold — the exact stop this feature removes.
      state =
        TurnPipeline.reset_per_turn_fields(
          Map.merge(base_state(sid()), %{
            compaction_continues: 3,
            just_compacted: true,
            just_compacted_overflow: true,
            overflow_retries: 1,
            recent_failure_signatures: ["x"],
            doom_recovery_count: 1,
            exploration_done: true
          })
        )

      assert state.compaction_continues == 0
      refute state.just_compacted
      refute state.just_compacted_overflow
    end
  end
end
