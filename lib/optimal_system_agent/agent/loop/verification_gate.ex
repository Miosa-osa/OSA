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

  ## The four questions, weakest to strongest

  When the agent is about to finish a turn (the model emitted no tool calls)
  after having changed files, the gate asks, in order:

    0. `:unobserved_background` — is a background command this session started
       STILL RUNNING? Then the turn is finishing on work it has not seen.
       (**Engagement**. See below.)
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

  **It costs turns on purpose — but the cost is now priced to the change.**
  Clause 3 as first shipped charged every change the same: measured on a
  one-line bug fix in a live session, 6 tool calls / 7 turns without it versus
  10 / 12 with it, and separately a 14-call verification tangent after a correct
  one-line fix. That is the right price for authoring a module and the wrong
  price for a tweak, and a gate that expensive can lose a task outright by
  running it into a wall-clock ceiling.

  ## Proportionality (clause 3 only)

  `VerificationEvidence.change_scale/1` sorts the session's source writes into
  `:none | :small | :large`, and the tier decides three things:

  | | `:small` (one site, ≤1 file, ≤20 lines, in-place) | `:large` (authored a file, or wider) |
  |---|---|---|
  | discharged by | the project's own suite passing, **or** a discriminating test | a discriminating test only |
  | `NO_RUNNABLE_TEST` honoured | immediately | from the second pushback |
  | re-prompt cap | #{2} | #{3} |

  Preferring a suite the project already has is the largest saving available
  and the *strongest* evidence, not the weakest: the model did not write it, so
  it cannot have written it in order to pass this gate. It is refused when the
  session authored any test artefact, when a suite was narrowed with
  `--ignore`/`--deselect`, or when a command removed a test file.

  Authoring a whole file is never `:small`, whatever its line count — that is
  the `cancel-async-tasks` shape, and it keeps full strength.

  Clauses 1 and 2 are tier-blind. Every code change, however small, must still
  have had something run and pass against it, and may never end on a red check.

  `config :optimal_system_agent, :verification_adequacy, false` (or
  `OSA_VERIFICATION_ADEQUACY=0`) turns clause 3 off entirely.

  ## Clause 0 — engagement, and what it is NOT

  A benchmark arm turned up a cluster of failures that ended `status=ok` with
  no self-inflicted markers and passed all three clauses above. The hypothesis
  was "turns that did not think", proxied by wall clock: under 5 s/turn against
  7.7 s/turn for solves.

  **That proxy does not survive the larger sample, and neither does any
  reasoning-volume signal.** Replayed over 60 graded trials of
  `bench/terminalbench/runs/osa-tb20-full89-f6981b61` (see
  `scripts/engagement_replay.py`):

  | signal | fires on failures | fires on solves |
  |---|---|---|
  | wall clock < 5 s/turn | 7/19 | 12/34 |
  | zero reasoning on the final turn | 15/19 | 30/34 |
  | episode reasoning chars/turn < 200 | 6/19 | 8/34 |

  A third of the solves are fast. `fix-code-vulnerability` solved at 2.2 s/turn
  with 19 reasoning characters per turn — the least "engaged" episode in the
  entire set, and correct. Any of those detectors punishes fast correct work,
  which is worse than not detecting at all.

  What the transcripts actually show is narrower, mechanical, and directly
  readable:

      hf-model-inference  "I'll run the full test suite the moment the download completes."
      sqlite-with-gcov    "I'll wait for the completion notification rather than re-checking."
      train-fasttext      "I'll wait for its completion notification, then re-run this test."
      query-optimize      "Waiting for the background test to complete on its own."

  Each ended its final turn while a background command **it had started** was
  still running, deferring the verification to a notification that never
  arrives — because the episode ends when the model stops.

  The harness invites this, in as many words. `shell_execute`'s prompt
  (`tools/builtins/shell_execute/prompt.ex`) says "You WILL be notified
  automatically when a background command finishes… Do unrelated work, or stop
  and let the notification wake you", and `query-optimize` quoted it back:
  "I was told I'd be notified on completion. I'll stop calling it and wait."

  That instruction is TRUE in a persistent session — `BackgroundNotifier`
  queues the completion and `Loop.poke/1` wakes an idle loop with a synthetic
  turn — and FALSE in a one-shot or headless run, where the loop is torn down
  the moment the model returns a final answer. The prompt cannot know which it
  is in; the gate can, because it asks about state rather than about the
  future. That is why the fix lives here and not in the tool description, and
  why the directive below does not claim the notification will never come.

  So clause 0 asks a fact, not a proxy: **at the moment of the completion
  claim, is a background command from this session still in the `:running`
  state?** That is a lookup in `Shell.BackgroundManager`, costs nothing, and
  cannot be confounded by provider latency, model, or task difficulty.

  Replayed against the same 60 trials: **fires on 9 of 19 model failures and 0
  of 34 solves** — and on 6 of the 7 failures the wall-clock proxy flagged. It
  is silent on both timeouts and on all three unsound tasks. The only episode
  in the set that ends with background work in flight *and* is a solve is
  `path-tracing`, which was killed at the 1800 s deadline and never made a
  completion claim at all; keying on the claim rather than on end-of-episode is
  what keeps it quiet there.

  It is deliberately NOT a turn cap, an episode-length cap, or anything derived
  from turn counts or wall clock. `path-tracing` solved at 170 turns and
  `build-pov-ray` failed at 62; neither number is evidence.

  **Clause 0 spends its own budget, and it is what makes this a block rather
  than a detector.** It first shipped sharing the single per-turn counter with
  clauses 1-3, which capped the whole gate at one pushback per turn — so the
  turn got exactly one refusal and then finished anyway, with the job still
  running. That is a detector with extra steps. It now carries
  `:background_gate_prompts` / `@max_background_reprompts` (3), independent of
  the adequacy budget in both directions: a clause-0 pushback cannot consume the
  adequacy budget, and an adequacy pushback earlier in the turn cannot silence
  clause 0. Its detection cost is still a registry lookup, not tokens.

  The other half of "actually blocks" is that the refusal must have somewhere to
  go. It did not: `bash_output` returned instantly and its own prompt said "DO
  NOT USE THIS TOOL TO WAIT", so "wait for it" was an instruction with no
  implementation and three pushbacks would have burned in seconds. `bash_output`
  now takes `wait_ms` and blocks; the directive below names it.

  `BACKGROUND_INTENTIONAL: <reason>` in the answer releases it immediately —
  the honest case is a long-lived service the model started on purpose. Note
  that such a service should not be a background command at all (see §3 of the
  taxonomy: a background command is a supervised child of the session and is
  reaped by `fire_session_end/2`), which is why the directive says how to
  daemonise instead.

  `config :optimal_system_agent, :verification_engagement, false` (or
  `OSA_VERIFICATION_ENGAGEMENT=0`) turns clause 0 off entirely.

  Known blind spot, stated rather than papered over: 10 of the 19 model
  failures are invisible to it, including `build-pov-ray`, which ran 62 turns
  at 4.4 s/turn and started no background command at all. Clause 0 detects one
  species of unengaged completion. It does not detect "shallow" in general, and
  nothing measured here does.

  It cannot trap the loop:

    * A non-code change (docs, config) never reaches clause 3 at all.
    * `NO_RUNNABLE_TEST: <reason>` in the answer releases clause 3 — explicit,
      logged, and unavailable for clause 2.
    * Re-prompts are capped per turn, reset by
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
  # ONE. It was 3, on the theory that satisfying the adequacy clause is a
  # write -> test -> fix loop and needs room to complete. The A/B says
  # otherwise: on both `fix-code-vulnerability` and `feal-differential` the
  # counter ran 1 -> 2 -> 3, hit the cap, and stepped aside UNSATISFIED — and
  # both tasks passed anyway. Those two extra pushbacks converted nothing and
  # cost 37-41% of each task's tokens. A model that has declined the ask twice
  # is not about to accept it on the third try; it is spending budget that a
  # timeout-bound task needs, and a timeout turns a possible solve into a
  # guaranteed failure at full price.
  #
  # So the gate now makes its case once, cheaply, and gets out of the way. It
  # resets every turn (`TurnPipeline.reset_per_turn_fields/1`), so a genuinely
  # unverified session is still asked again on the next turn.
  @max_reprompts 1

  # Clause 0 gets its OWN budget, and a bigger one. Sharing `@max_reprompts`
  # with the ledger clauses is what made clause 0 a detector rather than a
  # block: one pushback, and on the next text-only answer the counter is at the
  # cap and the gate steps aside — with the job still running, which is the
  # exact state it exists to refuse.
  #
  # The cap-of-1 argument does not transfer. It rests on "a model that has
  # declined the ask twice is not about to accept it on the third try", which is
  # true of adequacy (write a discriminating test — an argument about taste) and
  # false here. Clause 0's ask is mechanical, its exit is a single blocking
  # `bash_output` call with `wait_ms`, and — unlike every other clause — THE
  # WORLD CHANGES BETWEEN PUSHBACKS: the job is advancing in real time, so the
  # same question can get a different answer without the model doing anything
  # differently.
  #
  # Three, not unbounded: the gate must never be able to trap the loop, and a
  # model that will not block after three asks is not going to. The
  # `BACKGROUND_INTENTIONAL:` escape still releases it immediately at any point.
  @max_background_reprompts 3

  # Where a test the gate ASKED FOR is allowed to land.
  #
  # This gate shipped a directive that destroyed two deliverables. `polyglot-c-py`
  # and `polyglot-rust-c` both want exactly one file in `/app/polyglot`, and both
  # verifiers assert it as their FIRST line:
  #
  #     assert polyglot_files == ["main.rs"], f"Expected only main.rs, found: …"
  #     # found: ['test_polyglot.py', 'main.rs', 'cpp_fib', '__pycache__', 'rust_fib']
  #
  # Every extra entry is ours: the persisted test file this gate demanded, the
  # `__pycache__` Python wrote beside it, and the binaries the test compiled. The
  # solutions themselves were very likely correct and were never evaluated,
  # because the directory listing failed first.
  #
  # Replayed over the reference run, 12 of 89 trials wrote a test artefact into a
  # directory the instruction names as a deliverable — 10 of them SOLVES that
  # happened not to be graded on directory contents. So this is not a rare shape
  # we got unlucky with once; it is the default behaviour of the directive, and
  # it is a loaded gun pointed at any workspace-graded task.
  #
  # The fix is the location, not the artefact. Deleting the test after the run
  # would also clear the directory, and it would destroy the one thing that
  # makes the evidence worth having — a check the grader, or the next engineer,
  # can run again. Writing it somewhere harmless costs nothing and keeps both.
  # `VerificationEvidence`'s `@test_dir_segments` carries the matching entry so
  # a file placed here still counts as a test artefact.
  @scratch_test_dir "/tmp/osa-tests/"

  # The explicit, auditable escape. A task can genuinely have no runnable test
  # (documentation, a config value, a change with no harness in the image). The
  # automatic half of the escape is `code_file?/1` — a docs-only change never
  # triggers the adequacy requirement at all. This is the manual half, for the
  # cases the extension heuristic cannot see.
  #
  # Only honoured from the SECOND pushback onward, so it cannot be used to skip
  # the requirement without having been asked once and having tried.
  @no_test_marker ~r/NO[_\s-]?RUNNABLE[_\s-]?TEST\s*:/i

  # The escape for clause 0. A long-lived service the model started on purpose
  # — a dev server, a daemon under test — is `:running` forever by design, and
  # "wait for it to finish" is the wrong instruction for it.
  #
  # Honoured IMMEDIATELY rather than from the second pushback, for the same
  # reason `:small` gets `NO_RUNNABLE_TEST` immediately: charging a round trip
  # to say a true and cheap thing is most of what the benign case would pay.
  # It is explicit, it is logged, and it cannot touch clauses 1-3 — a server
  # left running still has to have had something run and pass against it.
  @background_ok_marker ~r/BACKGROUND[_\s-]?INTENTIONAL\s*:/i

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

    session_id != nil and
      case triaged(session_id, reprompts, content) do
        {nil, _scale} -> false
        {:unobserved_background, _scale} -> background_prompts(state) < @max_background_reprompts
        {_reason, scale} -> reprompts < cap_for(scale)
      end
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
    {reason, _scale} = triaged(session_id, reprompts, content)
    reason
  end

  @doc """
  The unanswered question **and the risk tier it was priced at**.

  The tier (`VerificationEvidence.change_scale/1`) decides three things and
  nothing else: what discharges the adequacy clause, when the explicit escape is
  honoured, and how many pushbacks are available. The red-check and
  unchecked-write clauses are tier-blind — every code change, however small,
  must still have had something run and pass against it.
  """
  @spec triaged(term(), non_neg_integer(), String.t() | nil) ::
          {atom() | nil, :none | :small | :large}
  def triaged(session_id, reprompts \\ 0, content \\ nil) do
    scale = VerificationEvidence.change_scale(session_id)

    reason =
      cond do
        # Clause 0 first, and ahead of the ledger clauses on purpose: while a
        # job this session started is still running, every other answer the
        # gate could give is provisional. It is also the cheapest of the four
        # (a registry lookup, no ledger scan).
        background_pending?(session_id, content) -> :unobserved_background
        VerificationEvidence.failing_check_since_write(session_id) != nil -> :failing_check
        VerificationEvidence.pending_files(session_id) != [] -> :unchecked_write
        not adequacy_enabled?() -> nil
        not VerificationEvidence.needs_discriminating_test?(session_id) -> nil
        adequate_for_scale?(scale, session_id) -> nil
        escaped?(scale, reprompts, content) -> nil
        true -> :inadequate_test
      end

    {reason, scale}
  end

  # What discharges the adequacy clause, by tier.
  #
  # `:large` — a persisted test that failed once and then passed across a source
  # fix. Unchanged, and deliberately so: authoring a file is the shape the
  # requirement was built for and the shape the extra solve came from.
  #
  # `:small` — that, OR the project's own suite passing. A green pre-existing
  # suite is evidence the model did not write and therefore cannot have written
  # in order to pass this gate, it proves the one-site edit regressed nothing,
  # and it costs a single command instead of a red -> fix -> green cycle. It is
  # NOT accepted for `:large`, where "regressed nothing" is not the claim at
  # issue.
  defp adequate_for_scale?(:none, _session_id), do: true

  defp adequate_for_scale?(:small, session_id),
    do: VerificationEvidence.external_suite_pass?(session_id)

  defp adequate_for_scale?(_large, _session_id), do: false

  defp cap_for(_scale), do: @max_reprompts

  @doc """
  The clause-0 re-prompt counter. Separate from `:verification_gate_prompts` so
  a pushback about unobserved background work neither consumes nor is consumed
  by the adequacy budget. Reset per turn by
  `TurnPipeline.reset_per_turn_fields/1`, same as its sibling.
  """
  @spec background_prompts(map()) :: non_neg_integer()
  def background_prompts(state), do: Map.get(state, :background_gate_prompts, 0)

  # Which per-turn counter a given clause spends, and what it may spend.
  defp counter_for(:unobserved_background), do: :background_gate_prompts
  defp counter_for(_), do: :verification_gate_prompts

  defp cap_for_reason(:unobserved_background, _scale), do: @max_background_reprompts
  defp cap_for_reason(_reason, scale), do: cap_for(scale)

  @doc """
  Background commands **this session started** that are still `:running`.

  The engagement signal of clause 0, and a directly observable fact rather than
  a proxy: no wall clock, no token count, no turn count. Returns `[]` when the
  detector is switched off, when there is no session, or when the background
  manager is unavailable — every failure mode is silence, never a false fire.
  """
  @spec unobserved_background(term()) :: [map()]
  def unobserved_background(session_id) when is_binary(session_id) do
    if engagement_enabled?() do
      background_module().list()
      |> Enum.filter(fn snap ->
        Map.get(snap, :status) == :running and Map.get(snap, :session_id) == session_id
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def unobserved_background(_), do: []

  defp background_pending?(session_id, content) do
    not background_escaped?(content) and unobserved_background(session_id) != []
  end

  defp background_escaped?(content) when is_binary(content),
    do: Regex.match?(@background_ok_marker, content)

  defp background_escaped?(_), do: false

  # Injection seam. Production resolves to the real manager; tests substitute a
  # stub so the clause can be exercised without spawning real processes.
  defp background_module do
    Application.get_env(
      :optimal_system_agent,
      :background_manager,
      OptimalSystemAgent.Shell.BackgroundManager
    )
  end

  # Kill switch for clause 0 alone, matching the adequacy switch in shape so
  # there is one convention to remember. Clauses 1-3 are unaffected.
  defp engagement_enabled? do
    case System.get_env("OSA_VERIFICATION_ENGAGEMENT") do
      v when v in ["0", "false", "off", "no"] ->
        false

      _ ->
        Application.get_env(:optimal_system_agent, :verification_engagement, true) != false
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

  # When the escape becomes readable.
  #
  # `:large` — from the SECOND pushback, so it cannot be used to skip the
  # requirement without having been asked once and having tried.
  #
  # `:small` — immediately. Requiring a wasted round-trip before a one-line fix
  # may say "this repo has no test harness" is most of what the trivial case was
  # paying for, and the sentence is explicit, logged, and still cannot touch the
  # liveness clause: something must have run and passed either way.
  defp escaped?(:small, _reprompts, content) when is_binary(content),
    do: Regex.match?(@no_test_marker, content)

  defp escaped?(_scale, reprompts, content) when is_binary(content) and reprompts >= 1,
    do: Regex.match?(@no_test_marker, content)

  defp escaped?(_, _, _), do: false

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
    session_id = Map.get(state, :session_id)
    {reason, scale} = triaged(session_id, reprompts, content)
    reason = reason || :unchecked_write

    # Clause 0 spends its own counter (see `@max_background_reprompts`); every
    # other clause spends the shared adequacy budget.
    counter = counter_for(reason)
    step = Map.get(state, counter, 0) + 1
    cap = cap_for_reason(reason, scale)
    last_write = session_id && VerificationEvidence.last_write_tool(session_id)

    Logger.info(
      "[verification-gate] #{reason} scale=#{scale} " <>
        "(last write tool: #{last_write || "unknown"}) — " <>
        "injecting directive #{step}/#{cap} (session: #{inspect(session_id)})"
    )

    Bus.emit(:system_event, %{
      event: :verification_gate_triggered,
      session_id: session_id,
      reason: reason,
      # Emitted so the A/B can attribute cost to the tier that incurred it
      # rather than to "the gate" as an undifferentiated whole.
      scale: scale,
      # Where the session's oracle came from — `:external`, `:self_authored`,
      # `:none`. An observation, not a verdict: the species-2 failures and the
      # solves are indistinguishable by every episode-shape proxy tried so far
      # (see `VerificationEvidence.oracle_provenance/1`), and this is the one
      # fact that would settle the remaining hypothesis. Recorded so the next
      # run answers it instead of the next reader re-deriving it.
      oracle: session_id && VerificationEvidence.oracle_provenance(session_id),
      last_write_tool: last_write,
      reprompt: step,
      max_reprompts: cap,
      # Which per-turn budget this pushback spent. Clause 0 blocks on its own
      # counter, so a run's telemetry has to say which one moved or the two are
      # indistinguishable after the fact.
      counter: counter,
      # The concrete thing being refused, so a replay can attribute a blocked
      # completion to the jobs that caused it without re-reading the transcript.
      background_running:
        if(reason == :unobserved_background,
          do: session_id |> unobserved_background() |> Enum.map(& &1[:id]),
          else: []
        )
    })

    directive = %{
      # `user`, not `system` — this directive is appended after assistant TEXT,
      # and Anthropic/Gemini reject a system message in that position with a
      # 400. That made the verification gate a no-op on those families: it
      # never ran once. See react_loop's handle_result for the full note.
      role: "user",
      content: body(reason, session_id, step, cap, scale)
    }

    {directive, Map.put(state, counter, step)}
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

  defp header(step, cap), do: "[VERIFICATION REQUIRED #{step}/#{cap}] "

  defp body(:inadequate_test, session_id, step, cap, :small),
    do: small_change_body(session_id, step, cap)

  defp body(reason, session_id, step, cap, _scale), do: body(reason, session_id, step, cap)

  # A one-site edit of a handful of lines. The evidence that fits it is the
  # project's own suite, which costs one command when it exists and is stronger
  # than anything the model could write here — so this asks for that first and
  # names the way out when there is no suite, instead of opening with a
  # red -> fix -> green cycle the change does not warrant.
  defp small_change_body(session_id, step, cap) do
    changed = (session_id && VerificationEvidence.changed_source_files(session_id)) || []

    target =
      case changed do
        [] -> "your change"
        [one] -> "`#{Path.basename(one)}`"
        many -> Enum.map_join(Enum.take(many, 3), ", ", &"`#{Path.basename(&1)}`")
      end

    header(step, cap) <>
      "You made a small, single-site change to #{target} and nothing has tested it.\n\n" <>
      "Cheapest sufficient evidence, in order — take the first that applies:\n" <>
      "  1. The project already has a test suite: run it (`mix test`, `pytest`, " <>
      "`go test ./...`, `npm test`, `./run_tests.sh`) and report what it printed. " <>
      "Run the WHOLE suite — not a subset, and do not skip or deselect anything.\n" <>
      "  2. No suite exists, but the change is testable: add a persisted test that " <>
      "fails before your fix and passes after it. Put it in the project's test " <>
      "directory, or in `#{@scratch_test_dir}` — never beside the deliverable.\n" <>
      "  3. Neither is possible in this environment: answer " <>
      "`NO_RUNNABLE_TEST: <one-line reason>` on its own line and finish.\n\n" <>
      "Do not manufacture a throwaway inline snippet, and do not build a " <>
      "red -> fix -> green cycle by hand for a change this size — find the suite first."
  end

  # Clause 0. The correction is specific and small: you are about to report on
  # something you have not seen. It names the command, so the model does not
  # have to go looking, and it names all three exits — wait, kill, or declare
  # the job deliberate — so the turn has somewhere to go that is not "argue".
  #
  # It does NOT say "keep working" or "you stopped too early". The episodes
  # this catches include one that ran 62 turns; the defect is the claim resting
  # on unobserved work, not the length of the run.
  defp body(:unobserved_background, session_id, step, cap) do
    running = (session_id && unobserved_background(session_id)) || []

    listed =
      running
      |> Enum.take(3)
      |> Enum.map_join("\n", fn snap ->
        "  * `#{Map.get(snap, :id)}`: #{String.slice(to_string(Map.get(snap, :command) || "?"), 0, 200)}"
      end)

    header(step, cap) <>
      "You are finishing while #{length(running)} background command(s) you started " <>
      "are STILL RUNNING:\n" <>
      listed <>
      "\n\nA completion notification MAY wake you afterwards, and it may not — a " <>
      "one-shot or headless run ends when you stop, and then nothing does. Either " <>
      "way you have not seen this result yet, so any claim that rests on it is a " <>
      "guess right now, and \"I'll check once it completes\" is not a finished " <>
      "turn.\n\n" <>
      "Take one of these, now:\n" <>
      "  1. BLOCK ON IT IN ONE CALL: `bash_output` with the background_id above and " <>
      "`wait_ms` (e.g. 600000). That waits until it reaches a terminal status and " <>
      "hands you its exit code and output — then report what it actually printed and " <>
      "whether it passed. Do NOT call `bash_output` without `wait_ms` in a loop; a " <>
      "bare call returns instantly and tells you nothing new.\n" <>
      "  2. If waiting is not affordable, kill it (`bash_output` with `kill: true`) " <>
      "and do the same work synchronously in the foreground, so you see the result.\n" <>
      "  3. If it is a long-lived service you started deliberately and it is " <>
      "SUPPOSED to keep running (a server under test, a daemon), say so on its own " <>
      "line as `BACKGROUND_INTENTIONAL: <one-line reason>` and finish. Note that a " <>
      "background command is a child of THIS SESSION and is killed when the session " <>
      "ends — if something has to still be listening after you finish, restart it " <>
      "detached (`setsid nohup <cmd> </dev/null >/tmp/<name>.log 2>&1 &`) and verify " <>
      "it independently before you say so.\n\n" <>
      "Do not report a result you have not observed, and do not promise to check " <>
      "it later."
  end

  defp body(:failing_check, session_id, step, cap) do
    failing = VerificationEvidence.failing_check_since_write(session_id)
    cmd = (failing && Map.get(failing, :command)) || "your last check"

    header(step, cap) <>
      "A check RAN AND FAILED after your most recent edit:\n" <>
      "  #{String.slice(to_string(cmd), 0, 300)}\n" <>
      "You are about to finish on a red check. Do not. Diagnose the failure, fix the " <>
      "SOURCE (not the test), and re-run the same command until it passes. Report the " <>
      "before/after output."
  end

  defp body(:unchecked_write, session_id, step, cap) do
    pending = (session_id && VerificationEvidence.pending_files(session_id)) || []

    files_note =
      case pending do
        [] -> "the file(s) you changed"
        [one] -> "`#{one}`"
        many -> Enum.map_join(many, ", ", &"`#{&1}`")
      end

    header(step, cap) <>
      "You modified #{files_note} but nothing has RUN and PASSED against it since. " <>
      "An unrelated read, a command that only printed the file, or a failed command do " <>
      "not count. Run something that can fail — the project's build, its linter, or " <>
      "better, its tests — and report what it printed."
  end

  defp body(:inadequate_test, session_id, step, cap) do
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

    header(step, cap) <>
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
      where_it_goes() <>
      "\n\n" <>
      what_it_must_check(session_id) <>
      "\n\n" <>
      "NEVER un-fix working code to produce a red run. Do not revert, stash, or " <>
      "overwrite a corrected file so a test will fail — on a task graded by final " <>
      "state, an interruption mid-cycle ships the broken version, and on a security " <>
      "fix that means shipping the vulnerability. That is a worse outcome than any " <>
      "amount of missing evidence.\n\n" <>
      "Get the red run without damaging anything:\n" <>
      "  * If a run earlier in this session already failed on this test or suite, you " <>
      "are done — say which one and finish.\n" <>
      "  * If you have not written the test yet and are still going to change the " <>
      "source, write the test FIRST and run it now, while it still fails on its own.\n" <>
      "  * If your fix has already landed and the test has only ever been green, say " <>
      "so plainly and finish. Do not manufacture a failure.\n\n" <>
      "If this task genuinely admits no runnable test — pure documentation, a config " <>
      "value, no harness in the environment — say so explicitly on its own line, as " <>
      "`NO_RUNNABLE_TEST: <one-line reason>`, and finish. Do not use that to skip work " <>
      "you could have tested."
  end

  # ---------------------------------------------------------------------------
  # Species 6: this gate's test file must not become part of the deliverable
  # ---------------------------------------------------------------------------
  #
  # See `@scratch_test_dir`. Named in every directive that asks for a test file,
  # because the two tasks it cost us were both lost on the FIRST line of the
  # verifier, before any of the work was looked at.
  defp where_it_goes do
    "WHERE the file goes matters as much as what it asserts. Use the project's " <>
      "existing test directory if it has one; otherwise write it under " <>
      "`#{@scratch_test_dir}` — NEVER in the directory that holds the deliverable. " <>
      "Some tasks are graded on the exact contents of a directory, and one stray " <>
      "`test_x.py`, `__pycache__` or compiled binary there fails the whole task with " <>
      "the real work untouched and unread. Send anything your test compiles to the " <>
      "same scratch directory (`-o #{@scratch_test_dir}bin`, `--target-dir`), and run " <>
      "Python with `PYTHONDONTWRITEBYTECODE=1` so it leaves no cache next to the code."
  end

  # ---------------------------------------------------------------------------
  # Species 2: a green test proves only the proposition IT states
  # ---------------------------------------------------------------------------
  #
  # This is the largest open failure mode in the benchmark and the only one with
  # no detector. Nine tasks wrote a genuine persisted test, ran it red, fixed the
  # source, ran it green — satisfying every clause above completely — and the
  # test measured the wrong property:
  #
  #   * `model-extraction-relu-logits` asserted PRECISION ("20/25 stolen rows
  #     matched a true neuron"); the verifier measures RECALL (27 of 30 true rows
  #     unmatched).
  #   * `torch-tensor-parallelism` reported `ALL TESTS PASSED` for world sizes
  #     1/2/4 — its test performed the all-gather the implementation was
  #     supposed to perform. The test did the work under test.
  #   * `sanitize-git-repo` re-grepped for the four secrets IT had found, with
  #     the pattern list IT had written, after a discovery pass IT had truncated
  #     with `| head -80`. A fifth token sat below the cut. Its oracle inherited
  #     the exact blind spot of its implementation.
  #
  # Nothing downstream of the test can separate these from the solves, because
  # the solves did the same thing: `custom-memory-heap-crash`, `headless-terminal`,
  # `merge-diff-arc-agi-task` and `video-processing` all wrote a persisted test,
  # produced a red -> green cycle, and were right. Every proxy tried is recorded
  # in `docs/research/failure-taxonomy.md` §2.4 as rejected.
  #
  # So the gate stops asking about the test and asks about the CORRESPONDENCE
  # between the test and the task. This costs no extra pushback — it is the same
  # message the gate was already sending, re-aimed — and it is the only lever
  # that acts on the difference, because the difference is not in the transcript.
  # It is grounded in the sense that matters here: the thing being compared
  # against is the task statement, which the model did not write.
  #
  # It is NOT claimed to be validated. Ungrounded self-correction generally does
  # not help (CRITIC; Huang et al.), and this is a self-report. What it is not is
  # a re-judgement of the answer: enumerating which sentence of an external text
  # each assertion covers is a coverage question with a checkable shape, and the
  # measured contrast that motivates it — `dna-insert` solved after calibrating
  # against `oligotm`, `dna-assembly` failed on the one requirement stated only
  # in prose ("check that the enzyme cut-sites satisfy NEB's requirements") after
  # reasoning it out correctly across 2,500 lines and never asserting it — is a
  # coverage gap, not a reasoning error.
  defp what_it_must_check(session_id) do
    provenance = (session_id && VerificationEvidence.oracle_provenance(session_id)) || :none

    anchor =
      if provenance == :self_authored do
        "Every re-runnable check in this session is a file you wrote in this session, " <>
          "so nothing you did not author has had the chance to disagree with you yet. "
      else
        ""
      end

    "A passing test proves only the proposition IT states, and yours is a " <>
      "proposition you chose. #{anchor}Before you finish, check it against the task, " <>
      "not against your code:\n" <>
      "  * List the requirements the task actually states — including the ones written " <>
      "in prose with no obvious API, which are the ones that get dropped. Next to each, " <>
      "name the assertion that checks it, or say plainly that nothing does. A " <>
      "requirement you reasoned about and never asserted is not covered.\n" <>
      "  * Check the DIRECTION of each assertion. \"Everything I produced is correct\" " <>
      "is not \"everything required is present\" — those fail on opposite inputs.\n" <>
      "  * If your test performs a step the implementation was supposed to perform, it " <>
      "is testing your test. Drive the code exactly the way the task says it will be " <>
      "driven.\n" <>
      "  * If the task names a tool, fixture, file or command as the ground truth, THAT " <>
      "is the oracle. Run it and report its output. Do not substitute one you wrote, " <>
      "and do not derive your check's scope from your own earlier search — if that " <>
      "search missed something, so will the check."
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

    # Under the same switch as the clause it exists to serve. It was not, and it
    # fired in BOTH arms of the adequacy ablation — so the measured −31% priced
    # the pushback and not the feature, and the feature costs more than that
    # number says. `OSA_VERIFICATION_ADEQUACY=0` now silences the whole thing.
    if adequacy_enabled?() and changed != [] and known == [] do
      "You just changed code (#{Enum.map_join(Enum.take(changed, 3), ", ", &Path.basename/1)}). " <>
        "Establish how this gets tested NOW, while it is cheap:\n" <>
        "  1. FIRST look for a suite this project already has — `run_tests.sh`, `mix test`, " <>
        "`pytest`, `go test ./...`, a `test/` or `tests/` directory. Running one that exists " <>
        "is the strongest evidence available and costs a single command.\n" <>
        "  2. Only if there is none, write a PERSISTED test file — a real file such as " <>
        "`#{@scratch_test_dir}test_x.py`, invoked by path, never an inline " <>
        "`python3 - << EOF` snippet — run it against the CURRENT state so you see it fail, " <>
        "then fix the source until it passes.\n" <>
        "  3. Keep it OUT of the deliverable. Write it to the project's own test " <>
        "directory or to `#{@scratch_test_dir}`, never beside the files the task asked " <>
        "you to produce, and send compiled output and `__pycache__` there too. A task " <>
        "graded on the contents of a directory fails on a stray test file before anyone " <>
        "looks at your code.\n" <>
        "  4. Test what the TASK asked for, in the direction it asked for it — not what " <>
        "your implementation happens to do. If the task names a tool or file as the " <>
        "ground truth, use that one.\n" <>
        "Setting this up now is much cheaper than reconstructing it at the end."
    end
  rescue
    _ -> nil
  end
end
