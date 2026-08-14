defmodule OptimalSystemAgent.Agent.Loop.VerificationGate do
  @moduledoc """
  Grounded verification gate for turn completion.

  Research motivation: **CRITIC** (Gou et al.) and *"Large Language Models
  Cannot Self-Correct Reasoning Yet"* (Huang et al.) both show that
  *ungrounded* self-correction — a model re-judging its own output with no
  external signal — tends to leave accuracy flat or *degrade* it. Reliable
  correction requires **grounding**: an external tool that actually checks the
  claim. This gate enforces that discipline at the point the agent is about to
  declare a turn "done".

  ## The three questions, weakest to strongest

  When the agent is about to finish a turn (the model emitted no tool calls)
  after having changed files, the gate asks, in order:

    1. `:failing_check`   — did something RUN AND FAIL since the last write and
       not been superseded? Ending here is ending on a red test.
    2. `:unchecked_write` — has any grounded check PASSED against the changed
       file at all? (**Liveness**.)
    3. `:inadequate_test` — is there a **persisted, re-runnable test that
       failed at least once and then passed across a source fix**?
       (**Adequacy**.)

  Question 3 is the one that matters and the one that was missing. Liveness is
  satisfiable by a probe the model writes in order to satisfy it, and
  `docs/research/turn-count-diagnosis.md` §5.2 measured exactly that: on
  `cancel-async-tasks` OSA wrote zero test files, ran five throwaway
  `python3 - << 'PYEOF'` heredocs, declared "**Verified:**", and was wrong —
  in 13 turns. The harness that solved the task took 56, wrote four named test
  files, and iterated write -> test -> fix. This gate is that difference,
  encoded. See `VerificationEvidence` for the evidence rules.

  **It costs turns on purpose.** Measured on a one-line bug fix in a live
  session: 6 tool calls / 7 turns without the adequacy clause versus 10 / 12
  with it, and only the second run produced a test that had ever been red.
  `config :optimal_system_agent, :verification_adequacy, false` (or
  `OSA_VERIFICATION_ADEQUACY=0`) turns clause 3 off.

  It cannot trap the loop:

    * A non-code change (docs, config) never reaches clause 3 at all.
    * `NO_RUNNABLE_TEST: <reason>` in the answer releases clause 3 from the
      second pushback onward — explicit, logged, and unavailable for clause 2.
    * Re-prompts are capped at #{3} per turn (`@max_reprompts`), reset by
      `TurnPipeline.reset_per_turn_fields/1`. After the cap the gate steps
      aside unconditionally.

  This complements `Guardrails.needs_verification_gate?/1` (which targets the
  *zero-successful-tools* case) by covering the *wrote-but-never-checked* case.

  ## Usage (wired by the loop)

      if VerificationGate.needs_verification?(state) do
        {directive, state} = VerificationGate.build_directive(state)
        state = %{state | messages: state.messages ++ [directive], ...}
        run(state)
      end

  `build_directive/1` increments the per-turn re-prompt counter it stores in
  `state.verification_gate_prompts` and emits a `:system_event` on the Bus.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Events.Bus

  # Cap on how many times the gate may re-prompt within a single turn before
  # stepping aside. Keeps the completion path from looping forever.
  #
  # Raised from 2 to 3 when the adequacy requirement landed: satisfying it is a
  # write -> test -> fix loop, not a single command, so two pushbacks was not
  # enough room to complete one. It is still a hard cap — the loop cannot be
  # trapped — and it resets every turn (`TurnPipeline.reset_per_turn_fields/1`).
  @max_reprompts 3

  # The explicit, auditable escape. A task can genuinely have no runnable test
  # (documentation, a config value, a change with no harness in the image). The
  # automatic half of the escape is `code_file?/1` — a docs-only change never
  # triggers the adequacy requirement at all. This is the manual half, for the
  # cases the extension heuristic cannot see.
  #
  # Only honoured from the SECOND pushback onward, so it cannot be used to skip
  # the requirement without having been asked once and having tried.
  @no_test_marker ~r/NO[_\s-]?RUNNABLE[_\s-]?TEST\s*:/i

  @doc """
  Returns `true` when the current turn is about to finish with an *unverified*
  write and the re-prompt budget is not yet exhausted.

  "Unverified" is now an **evidence** query, not a name heuristic
  (`VerificationEvidence.pending_files/1`): a changed file counts as verified
  only when, *since its last write*, a grounded check **passed (exit 0)** and
  **referenced that file** (or ran a project build/test). An unrelated
  `file_read` or a non-zero `shell_execute` no longer satisfies the gate.
  """
  # A FAILING check is also a reason to continue, not only a missing one.
  #
  # This gate asked one question — "was the edit ever checked" — and a failing
  # check answered it in the affirmative, because the ledger recorded that a
  # check happened. `tool_executor` stores `success: false` for a red test and
  # the loop then discarded it. Two independent studies of our own transcripts
  # found the same thing: every harness examined gates on the ABSENCE of
  # verification and none on the PRESENCE of a failure.
  #
  # The two signals are different questions and both matter:
  #   pending_files/1               -> "this edit was never checked"
  #   failing_check_since_write/1   -> "this edit was checked and it failed"
  @spec needs_verification?(map()) :: boolean()
  def needs_verification?(state), do: needs_verification?(state, nil)

  @doc """
  As `needs_verification?/1`, but also given the assistant text the turn is
  about to finish with, so the explicit `NO_RUNNABLE_TEST:` escape can be read.
  """
  @spec needs_verification?(map(), String.t() | nil) :: boolean()
  def needs_verification?(state, content) when is_map(state) do
    reprompts = Map.get(state, :verification_gate_prompts, 0)
    session_id = Map.get(state, :session_id)

    reprompts < @max_reprompts and session_id != nil and
      trigger(session_id, reprompts, content) != nil
  end

  def needs_verification?(_, _), do: false

  @doc """
  Which of the three questions is unanswered, in priority order, or `nil`.

    * `:failing_check`  — a check RAN and FAILED since the last write. Ending
      here is ending on a red test.
    * `:unchecked_write` — a changed file has had no passing check at all
      (liveness).
    * `:inadequate_test` — code changed, and nothing in the transcript is a
      persisted, re-runnable test that failed at least once and then passed
      across a source fix (adequacy).
  """
  @spec trigger(term(), non_neg_integer(), String.t() | nil) :: atom() | nil
  def trigger(session_id, reprompts \\ 0, content \\ nil) do
    cond do
      VerificationEvidence.failing_check_since_write(session_id) != nil -> :failing_check
      VerificationEvidence.pending_files(session_id) != [] -> :unchecked_write
      not adequacy_enabled?() -> nil
      escaped?(reprompts, content) -> nil
      VerificationEvidence.needs_discriminating_test?(session_id) -> :inadequate_test
      true -> nil
    end
  end

  # Kill switch for the adequacy requirement alone. This is the one clause that
  # deliberately BUYS turns (measured: +5 tool calls / +6 turns on a one-line
  # bug fix), so it needs to be switchable without a redeploy of judgement.
  # The liveness and red-check clauses above are not affected.
  defp adequacy_enabled? do
    case System.get_env("OSA_VERIFICATION_ADEQUACY") do
      v when v in ["0", "false", "off", "no"] ->
        false

      _ ->
        Application.get_env(:optimal_system_agent, :verification_adequacy, true) != false
    end
  end

  defp escaped?(reprompts, content) when is_binary(content) and reprompts >= 1,
    do: Regex.match?(@no_test_marker, content)

  defp escaped?(_, _), do: false

  @doc """
  Build the grounded-verification directive and advance the per-turn re-prompt
  counter.

  Returns `{directive, updated_state}` where `directive` is a `system` message
  ready to append to `state.messages` and `updated_state` carries the
  incremented `:verification_gate_prompts` counter. Emits a `:system_event` on
  the Bus so the trigger is observable.
  """
  @spec build_directive(map()) :: {map(), map()}
  def build_directive(state) when is_map(state) do
    build_directive(state, nil)
  end

  @spec build_directive(map(), String.t() | nil) :: {map(), map()}
  def build_directive(state, content) when is_map(state) do
    reprompts = Map.get(state, :verification_gate_prompts, 0)
    step = reprompts + 1
    session_id = Map.get(state, :session_id)
    reason = trigger(session_id, reprompts, content) || :unchecked_write
    last_write = session_id && VerificationEvidence.last_write_tool(session_id)

    Logger.info(
      "[verification-gate] #{reason} (last write tool: #{last_write || "unknown"}) — " <>
        "injecting directive #{step}/#{@max_reprompts} (session: #{inspect(session_id)})"
    )

    Bus.emit(:system_event, %{
      event: :verification_gate_triggered,
      session_id: session_id,
      reason: reason,
      last_write_tool: last_write,
      reprompt: step,
      max_reprompts: @max_reprompts
    })

    directive = %{
      # `user`, not `system` — this directive is appended after assistant TEXT,
      # and Anthropic/Gemini reject a system message in that position with a
      # 400. That made the verification gate a no-op on those families: it
      # never ran once. See react_loop's handle_result for the full note.
      role: "user",
      content: body(reason, session_id, step)
    }

    {directive, Map.put(state, :verification_gate_prompts, step)}
  end

  # ---------------------------------------------------------------------------
  # Directive text
  # ---------------------------------------------------------------------------
  #
  # The previous version of this text listed "Re-read the edited file with
  # file_read to confirm the change landed" as a way to satisfy the gate — it
  # advertised the cheapest possible non-check, while `file_edit`'s own prompt
  # simultaneously told the model NOT to re-read after a successful edit. A
  # gate that publishes its own bypass is not a gate. Nothing below can be
  # discharged by looking at a file.

  defp header(step), do: "[VERIFICATION REQUIRED #{step}/#{@max_reprompts}] "

  defp body(:failing_check, session_id, step) do
    failing = VerificationEvidence.failing_check_since_write(session_id)
    cmd = (failing && Map.get(failing, :command)) || "your last check"

    header(step) <>
      "A check RAN AND FAILED after your most recent edit:\n" <>
      "  #{String.slice(to_string(cmd), 0, 300)}\n" <>
      "You are about to finish on a red check. Do not. Diagnose the failure, fix the " <>
      "SOURCE (not the test), and re-run the same command until it passes. Report the " <>
      "before/after output."
  end

  defp body(:unchecked_write, session_id, step) do
    pending = (session_id && VerificationEvidence.pending_files(session_id)) || []

    files_note =
      case pending do
        [] -> "the file(s) you changed"
        [one] -> "`#{one}`"
        many -> Enum.map_join(many, ", ", &"`#{&1}`")
      end

    header(step) <>
      "You modified #{files_note} but nothing has RUN and PASSED against it since. " <>
      "An unrelated read, a command that only printed the file, or a failed command do " <>
      "not count. Run something that can fail — the project's build, its linter, or " <>
      "better, its tests — and report what it printed."
  end

  defp body(:inadequate_test, session_id, step) do
    changed = (session_id && VerificationEvidence.changed_source_files(session_id)) || []
    known = (session_id && VerificationEvidence.known_test_artifacts(session_id)) || []

    target =
      case changed do
        [] -> "your change"
        [one] -> "`#{Path.basename(one)}`"
        many -> Enum.map_join(Enum.take(many, 3), ", ", &"`#{Path.basename(&1)}`")
      end

    have =
      case known do
        [] ->
          "You have not written or run a single persisted test file this session; every " <>
            "check so far was a throwaway inline snippet (`python3 - << EOF`, `-c \"...\"`, " <>
            "or similar). Those vanish. They cannot be re-run, reviewed, or shipped, and a " <>
            "snippet you wrote in order to pass this gate is not evidence."

        files ->
          "You have #{Enum.map_join(Enum.take(files, 3), ", ", &"`#{&1}`")}, but no run of " <>
            "it has ever FAILED and then passed across a fix. A test that has only ever " <>
            "passed may be testing nothing."
      end

    header(step) <>
      "You changed #{target}, but there is no evidence that what you changed actually " <>
      "works.\n\n" <>
      have <>
      "\n\nWhat counts as evidence, and nothing else does:\n" <>
      "  1. A PERSISTED test file on disk — `test_*.py`, `*_test.go`, `*_test.exs`, " <>
      "`*.spec.ts`, anything under `test/`, `tests/` or `spec/` — or the project's own " <>
      "test suite.\n" <>
      "  2. RE-RUNNABLE: you invoke it BY PATH (`python3 /tmp/test_x.py`, `pytest " <>
      "tests/test_x.py`, `mix test`), so it can be run again and it exercises the change.\n" <>
      "  3. It FAILED AT LEAST ONCE, and then passed after you edited the SOURCE. A test " <>
      "that fails before the fix and passes after it demonstrably discriminates; one that " <>
      "was green on its first run proves only that it ran. Editing the test to make it " <>
      "pass does not count — the fix has to be in the code under test.\n\n" <>
      "If the test is already green, that is not a reason to stop: make it red first. " <>
      "Revert the fix, or point the test at the behaviour you have NOT implemented yet, " <>
      "watch it fail, restore the fix, watch it pass.\n\n" <>
      "Take the turns this needs. Finishing early with a shallow check is the failure " <>
      "mode this is here to prevent, and it costs far more than the extra commands.\n\n" <>
      "If this task genuinely admits no runnable test — pure documentation, a config " <>
      "value, no harness in the environment — say so explicitly on its own line, as " <>
      "`NO_RUNNABLE_TEST: <one-line reason>`, and finish. Do not use that to skip work " <>
      "you could have tested."
  end

  @doc """
  One-shot steer surfaced next to the FIRST source edit of a session, so the
  write -> test -> fix loop is set up while it is cheap rather than demanded at
  the finish line.

  A gate that only fires when the agent tries to stop is a worse teacher than
  one that shapes the approach early: mini-swe-agent's advantage on
  `cancel-async-tasks` was not that it verified harder at the end, it was that
  it wrote `/tmp/test_run.py` at step 6 of 56 and then had something to iterate
  against. Returns `nil` when there is nothing to say.
  """
  @spec first_write_nudge(term()) :: String.t() | nil
  def first_write_nudge(session_id) do
    changed = VerificationEvidence.changed_source_files(session_id)
    known = VerificationEvidence.known_test_artifacts(session_id)

    if changed != [] and known == [] do
      "You just changed code (#{Enum.map_join(Enum.take(changed, 3), ", ", &Path.basename/1)}). " <>
        "Before going further, write a PERSISTED test file that fails against the current " <>
        "state — a real file such as `tests/test_x.py` or `x_test.exs`, invoked by path, not " <>
        "an inline `python3 - << EOF` snippet. Then fix the source until it passes. " <>
        "Completion requires a test that failed at least once and then passed; setting that " <>
        "up now is much cheaper than reconstructing it at the end."
    end
  rescue
    _ -> nil
  end
end
