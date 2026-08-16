defmodule OptimalSystemAgent.Agent.Loop.AnnouncementBackstopTest do
  @moduledoc """
  Species 7 of `docs/research/failure-taxonomy.md`: an episode whose last words
  announce the next action rather than report a result.

  `torch-pipeline-parallelism` is the clean instance — 29 turns, 493 s, no
  truncation, no guard, no background job, 14,000 characters of reasoning that
  had worked out the AFAB schedule correctly, and then:

      [SAY]  I have enough understanding. Let me write the implementation now.
      [DONE]

  Verifier: `File /app/pipeline_parallel.py does not exist`.

  ROOT CAUSE (measured from source, not inferred): `continue_on_text_only`
  defaults to `false` (`config/config.exs`), so `prose_continue?/1` is false and
  all three of the loop's text-only continuation clauses — including the one
  keyed on `wants_to_continue?/1`, which this very sentence matches — are dead.
  A text-only answer terminates the turn. That default is correct and stays:
  those clauses key on wording alone and fire on ordinary explanatory answers.

  The backstop below is narrower on purpose. It is the CONJUNCTION of
  announcement wording with brevity, which is `scripts/failure_species.py`'s
  `announced_next_action` predicate verbatim — 9 of 34 model failures and 0 of
  49 solves on the reference run. Length alone fires on solves at every
  threshold from 200 to 600 characters; wording alone is ordinary prose. Only
  the pair discriminates.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline

  # The subset of loop state `reset_per_turn_fields/1` updates with the
  # `%{state | ...}` syntax, which raises on a missing key.
  defp loop_state(extra) do
    Map.merge(
      %{
        session_id: "s1",
        iteration: 3,
        overflow_retries: 1,
        auto_continues: 2,
        status: :thinking,
        exploration_done: true,
        recent_failure_signatures: ["x"],
        doom_recovery_count: 1
      },
      extra
    )
  end

  describe "fires on the measured failures" do
    # Verbatim final responses from
    # `bench/terminalbench/runs/osa-tb20-full89-f6981b61`, quoted in the
    # taxonomy and reproduced by `scripts/failure_species.py`.
    test "torch-pipeline-parallelism" do
      assert Guardrails.announcement_only?(
               "I have enough understanding. Let me write the implementation now."
             )
    end

    test "fix-ocaml-gc" do
      assert Guardrails.announcement_only?(
               "The testsuite is running in the background. I'll report results when it completes."
             )
    end

    test "regex-chess" do
      assert Guardrails.announcement_only?(
               "Let me investigate the en-passant behavior in python-chess and understand " <>
                 "the test better before building the solution."
             )
    end
  end

  describe "stays quiet on real answers" do
    test "a short factual report is not an announcement" do
      refute Guardrails.announcement_only?(
               "Fixed. `pytest tests/` now reports 40 passed, 0 failed."
             )
    end

    test "brevity alone is not enough" do
      refute Guardrails.announcement_only?("Done.")
      refute Guardrails.announcement_only?("NO_RUNNABLE_TEST: no harness in this image.")
    end

    test "wording alone is not enough — a long explanation may narrate freely" do
      long =
        "Let me walk you through how the retry budget works. " <>
          String.duplicate(
            "The backoff is exponential with jitter, bounded by the ceiling in Limits. ",
            12
          )

      assert String.length(long) >= 500
      assert Regex.match?(~r/let me /i, long)
      refute Guardrails.announcement_only?(long)
    end

    test "nil and non-binaries are not announcements" do
      refute Guardrails.announcement_only?(nil)
      refute Guardrails.announcement_only?(:done)
    end

    test "large-scale-text-editing: \"I'll examine\" — the verb the list lacked" do
      # Measured on `bench/terminalbench/runs/osa-tb20-full89-9b57ee7d`:
      # ONE turn, ZERO tool calls, 2.16 seconds, and the entire episode was the
      # sentence below. The task was never attempted.
      #
      # The `i'll …` branch shipped with action verbs and no INVESTIGATION verbs
      # at all, so this fell through — while the very same sentence phrased
      # "Let me examine both files…" matched on the other branch. The
      # `:unstarted_task` shape exists for exactly this episode and could not
      # fire, because the wording did not match.
      assert Guardrails.announcement_only?(
               "I'll examine both files to understand the transformation needed."
             )

      # The `let me ` branch always covered it. The gap was narrow and specific.
      assert Guardrails.announcement_only?(
               "Let me examine both files to understand the transformation needed."
             )
    end

    test "the added investigation verbs all fire" do
      for verb <- ~w(examine inspect explore analyze analyse look read) do
        assert Guardrails.announcement_only?("I'll #{verb} the files first."),
               "expected \"I'll #{verb}\" to read as an announcement"
      end
    end

    test "check and review stay OUT of the i'll branch" do
      # Deliberate exclusions, not oversights.
      #
      # `check` is this repo's own documented over-firing hazard:
      # `deliverable_task?/1` omits it from the mutating verbs on purpose, and
      # `TextOnlyTurnTerminationTest`'s fixture is literally "Let me check the
      # configuration: …" as a COMPLETE answer that must cost one round trip.
      # `review` is the idiomatic offer "I'll review it and get back to you".
      #
      # Both are still reachable via the `let me ` branch, which is gated by the
      # loop's other conjuncts — this only keeps them off the unconditional
      # `i'll` branch.
      refute Guardrails.announcement_only?("I'll check that and get back to you.")
      refute Guardrails.announcement_only?("I'll review it once CI is green.")
    end

    test "\"I'll look into it\" is a sign-off, not an announcement" do
      # `look` is the one added verb whose future tense commonly CLOSES a
      # finished answer. Handled in `@courtesy_pattern`, the mechanism that
      # already exists for this, rather than by withholding the verb.
      refute Guardrails.announcement_only?(
               "Fixed in /app/main.py and the suite is green. I'll look into it if it recurs."
             )

      # …while the announcing use of the same verb still fires.
      assert Guardrails.announcement_only?("I'll look at both files to see what differs.")
    end

    test "a courtesy sign-off is not an announcement" do
      # "Let me know if …" matches the announcement pattern and is the opposite
      # of an announcement: the work is done and follow-up is being offered.
      refute Guardrails.announcement_only?(
               "Wrote /app/pipeline_parallel.py; the smoke test prints PASS. " <>
                 "Let me know if you want the benchmark numbers too."
             )

      # …but scrubbing the sign-off must not disarm a real announcement that
      # happens to carry one.
      assert Guardrails.announcement_only?(
               "Let me write the implementation now. Let me know if that's wrong."
             )
    end

    test "a session that only talked is a conversation, not an interrupted task" do
      # The second conjunct of the loop clause. `TextOnlyTurnTerminationTest`
      # pins a text-only answer at exactly one round trip, and its fixture —
      # "Let me check the configuration: the value lives in config/runtime.exs
      # and is read at boot, so changing it needs a restart." — matches the
      # wording predicate. It must not be continued, because nothing ran.
      chat = [%{role: "user", content: "explain the retry budget"}]
      assert Guardrails.talked_only?(chat)

      # Failed and blocked tool results do not count as having run anything.
      assert Guardrails.talked_only?(chat ++ [%{role: "tool", content: "Error: boom"}])
      assert Guardrails.talked_only?(chat ++ [%{role: "tool", content: "Blocked: denied"}])

      # A real tool result does.
      refute Guardrails.talked_only?(chat ++ [%{role: "tool", content: "use_cache True"}])
    end
  end

  describe "the unstarted task — the case the shipped backstop could not see" do
    # `not talked_only?/1` reads "a session that has only talked is a
    # conversation". That is right for a conversation and wrong for the FIRST
    # turn of a task, and the second case is the worse one.
    #
    # Verbatim from
    # `bench/terminalbench/runs/VOID-contended-probe-minimal-04061c68/harbor/
    #  2026-08-16__08-53-05/path-tracing__52TWkik/agent/osa-events.jsonl`:
    # one generation, 263 output tokens, ZERO tool calls, $0.00174, then [DONE].
    @path_tracing_answer "I'll start by examining the image to understand what I need to reproduce."

    # Verbatim opening of `bench/terminalbench/tasks/terminal-bench-2-1/
    # path-tracing/instruction.md` — the mutating verb ("Write") and the named
    # artefacts (`/app/image.ppm`, `image.c`) are what make it a deliverable
    # task rather than a question.
    @path_tracing_task "I've put an image at /app/image.ppm that I rendered programmatically. " <>
                         "Write a c program image.c that I can run and compile and will generate " <>
                         "an image that's as close as possible to the image I put here."

    # `TextOnlyTurnTerminationTest`'s fixture — a question, answered in prose,
    # with announcement wording. It must stay a complete turn.
    @conversation [
      %{role: "user", content: "check how the retry budget is configured and explain it to me"}
    ]
    @conversation_answer "Let me check the configuration: the value lives in config/runtime.exs " <>
                           "and is read at boot, so changing it needs a restart."

    test "path-tracing: announced the first action, called nothing, and stopped" do
      assert {:continue, :unstarted_task} =
               Guardrails.announcement_continue(
                 @path_tracing_answer,
                 [%{role: "user", content: @path_tracing_task}]
               )
    end

    test "large-scale-text-editing is the unstarted shape, end to end" do
      # The whole point of widening the verb list. Measured on
      # `runs/osa-tb20-full89-9b57ee7d`: one turn, zero tool calls, 2.16 s.
      # `announced_unstarted_task` is the species this episode is, and before
      # the widening `announcement_continue/2` returned `:stop` for it — the
      # session ended having never touched the task.
      assert {:continue, :unstarted_task} =
               Guardrails.announcement_continue(
                 "I'll examine both files to understand the transformation needed.",
                 [
                   %{
                     role: "user",
                     content:
                       "Rewrite /app/input.txt into /app/output.txt applying the " <>
                         "transformation described in /app/spec.md"
                   }
                 ]
               )
    end

    test "torch-pipeline-parallelism is still the interrupted-task shape" do
      worked = [
        %{role: "user", content: "implement the pipeline schedule in /app/pipeline_parallel.py"},
        %{role: "tool", content: "use_cache True"}
      ]

      assert {:continue, :interrupted_task} =
               Guardrails.announcement_continue(
                 "I have enough understanding. Let me write the implementation now.",
                 worked
               )
    end

    test "a question answered in prose is a complete turn" do
      assert :stop = Guardrails.announcement_continue(@conversation_answer, @conversation)
    end

    test "a coding task whose tools all FAILED has started — it is not this shape" do
      # `never_ran_a_tool?/1` is strictly stronger than `talked_only?/1`: a
      # session that tried and errored is a different failure, and continuing it
      # on announcement wording would re-enter a loop that is already stuck.
      tried = [
        %{role: "user", content: @path_tracing_task},
        %{role: "tool", content: "Error: gcc: command not found"}
      ]

      refute Guardrails.never_ran_a_tool?(tried)
      assert :stop = Guardrails.announcement_continue(@path_tracing_answer, tried)
    end

    test "the tighter ceiling — at zero tools the announcement is the whole episode" do
      long =
        @path_tracing_answer <>
          " " <> String.duplicate("Here is some further preamble about the plan. ", 6)

      assert String.length(long) > 200
      assert String.length(long) < 500
      # Still an announcement by the measured 500-char predicate…
      assert Guardrails.announcement_only?(long)
      # …but not the unstarted shape, which is calibrated on an episode that
      # produced nothing but the announcement.
      assert :stop =
               Guardrails.announcement_continue(long, [
                 %{role: "user", content: @path_tracing_task}
               ])
    end
  end

  describe "the loop's per-turn budget" do
    # `reset_per_turn_fields/1` is the single place the loop declares what is
    # per-turn. A counter added to the loop without an entry there leaks across
    # turns and silently self-disables the feature — which has happened three
    # times before (see its @doc).
    test "reset_per_turn_fields/1 zeroes the counter, including when absent" do
      reset =
        TurnPipeline.reset_per_turn_fields(
          loop_state(%{announcement_continues: 3, background_gate_prompts: 2})
        )

      assert reset.announcement_continues == 0
      assert reset.background_gate_prompts == 0

      # Both are lazily `Map.put`-ed by the features that use them, so a state
      # that never exercised either genuinely lacks the key.
      bare = TurnPipeline.reset_per_turn_fields(loop_state(%{}))
      assert bare.announcement_continues == 0
      assert bare.background_gate_prompts == 0
    end
  end

  # The predicate tests above are cheap and precise; these two prove the clause
  # is actually WIRED into the completion path, which is the half that was
  # missing — `torch-pipeline-parallelism` reached `[DONE]` with every
  # ingredient of the fix present except a clause that read them.
  describe "the loop clause" do
    alias OptimalSystemAgent.Agent.Loop.ReactLoop
    alias OptimalSystemAgent.Test.MockProvider

    setup do
      prev = %{
        provider: Application.get_env(:optimal_system_agent, :default_provider),
        text: Application.get_env(:optimal_system_agent, :mock_provider_final_text),
        max_iter: Application.get_env(:optimal_system_agent, :max_iterations)
      }

      Application.put_env(:optimal_system_agent, :default_provider, :mock)
      Application.put_env(:optimal_system_agent, :max_iterations, 12)

      on_exit(fn ->
        for {k, v} <- [
              default_provider: prev.provider,
              mock_provider_final_text: prev.text,
              max_iterations: prev.max_iter
            ] do
          if is_nil(v),
            do: Application.delete_env(:optimal_system_agent, k),
            else: Application.put_env(:optimal_system_agent, k, v)
        end
      end)

      :ok
    end

    defp run_with(text, messages) do
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, text)
      MockProvider.reset_round_trips()

      state =
        Map.from_struct(%OptimalSystemAgent.Agent.Loop{
          session_id: "announce-#{System.unique_integer([:positive])}",
          provider: :mock,
          model: "mock-model-1.0",
          iteration: 0,
          auto_continues: 0,
          messages: messages,
          tools: [],
          permission_mode: :ask,
          permission_tier: :full,
          working_dir: File.cwd!()
        })

      {_response, _state} = ReactLoop.run(state)
      MockProvider.round_trips()
    end

    @worked [
      %{role: "user", content: "implement the pipeline schedule in /app/pipeline_parallel.py"},
      %{role: "tool", content: "use_cache True"}
    ]

    test "an announcement after real work buys exactly one more turn" do
      n = run_with("I have enough understanding. Let me write the implementation now.", @worked)

      assert n == 2,
             "the announcement backstop must give the turn one more chance to act; cost #{n}"
    end

    test "it is bounded — it cannot run the turn to the iteration cap" do
      # The mock answers with the same announcement every time, i.e. the worst
      # case: a model that will not take the hint.
      n = run_with("Let me write the implementation now.", @worked)
      assert n == 2, "the backstop must be capped at one nudge; cost #{n} round-trips"
    end

    test "a real report after real work still ends the turn in one round-trip" do
      n = run_with("Wrote /app/pipeline_parallel.py; the smoke test prints PASS.", @worked)
      assert n == 1
    end

    @unstarted [%{role: "user", content: @path_tracing_task}]

    test "path-tracing's turn no longer ends after one zero-tool generation" do
      n = run_with(@path_tracing_answer, @unstarted)

      assert n == 2,
             "a coding task that announced its first action and called nothing must get " <>
               "one more chance to act; cost #{n} round-trips"
    end

    test "the unstarted branch is bounded by the same one-per-turn budget" do
      # The mock repeats the announcement, i.e. a model that will not take the
      # hint. Bounded at cap+1, not at `max_iterations`.
      n = run_with(@path_tracing_answer, @unstarted)
      assert n == 2, "the unstarted branch must be capped at one nudge; cost #{n}"
    end

    test "an exhausted budget ends the turn LOUDLY, not silently" do
      # The distinction the event carries: "the model reported a result" and
      # "the model announced again after being told to act" are different
      # endings, and used to look identical from outside the process.
      session = "announce-exhausted-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

      Application.put_env(:optimal_system_agent, :mock_provider_final_text, @path_tracing_answer)

      state =
        Map.from_struct(%OptimalSystemAgent.Agent.Loop{
          session_id: session,
          provider: :mock,
          model: "mock-model-1.0",
          iteration: 0,
          auto_continues: 0,
          messages: @unstarted,
          tools: [],
          permission_mode: :ask,
          permission_tier: :full,
          working_dir: File.cwd!()
        })

      {_response, final} = ReactLoop.run(state)

      assert_receive {:osa_event,
                      %{
                        type: :system_event,
                        event: :announcement_continue,
                        reason: :unstarted_task
                      }},
                     2000

      assert_receive {:osa_event,
                      %{
                        type: :system_event,
                        event: :announcement_continue_exhausted,
                        reason: :unstarted_task,
                        nudges_spent: 1
                      }},
                     2000

      # And the count is on the turn state, so `Observability.turn_end/2` can
      # report it next to `effort` and `reasoning`.
      assert Map.get(final, :announcement_continues) == 1

      assert OptimalSystemAgent.Observability.announcement_continue_count(final) == 1
    end
  end
end
