defmodule OptimalSystemAgent.Agent.Loop.GoalVerifier do
  @moduledoc """
  Goal-level verifier — an INDEPENDENT, read-only skeptic panel that judges
  whether the user's *goal* was met, not merely whether a file compiles.

  ## Why this exists (P1 — the biggest judgment gap)

  `Agent.Loop.VerificationGate` proves a narrower, cheaper claim: *"a file was
  written and a grounded check (build/test/lint) subsequently passed against
  it."* That is genuinely strong grounding, but it only re-prompts **the same
  model** that just wrote the code to decide whether the check was sufficient
  and whether the change is *correct/complete relative to the goal*. A change
  can pass `mix compile` and still be the wrong change, or half of the
  requested change.

  This module is the harness-owned goal-verification stage that closes that
  gap, modeled on grok-build's `session/goal_classifier.rs`
  (`GoalClassifierVerdict`, `GOAL_VERIFIER_SKEPTIC_COUNT`, majority-refute
  vote, run cap + stall early-exit): it spawns N **separate**, **read-only**
  subagents (fresh context, no access to how the work was produced) that are
  each instructed to try to REFUTE goal-completion, and aggregates their
  votes via strict majority-refute. Any not-refuted vote does NOT default to
  "achieved" on a tie or on missing data — uncertainty defaults to
  `:incomplete` (fail-closed), mirroring grok's "malformed/missing verdict
  maps to a synthetic refute" rule.

  ## Verdict

    * `:complete`   — a strict majority of skeptics did NOT refute goal
      completion.
    * `:incomplete` — a strict majority refuted, but did not judge the goal
      *unachievable* — another attempt is warranted.
    * `:off_track`  — a strict majority refuted AND a strict majority of
      those refuters judged the goal environmentally blocked/contradictory
      (not just "not yet done"). This should be surfaced to the model as a
      redirect, not a "try harder" nudge.

  ## Budget discipline

  Two independent, cheap circuit breakers bound the cost of this stage before
  it ever reaches for the expensive one (spawning a fresh subagent panel):

    * **Run cap** (`@max_runs`, mirrors `VerificationGate`'s `@max_reprompts`)
      — after N goal-verification rounds in a turn, the gate steps aside and
      lets the agent finish, exactly like the file-level gate.
    * **Stall early-exit** (`@stall_threshold`, mirrors grok's
      `GOAL_CLASSIFIER_STALL_THRESHOLD`) — if two consecutive rounds produce
      the *same* gap fingerprint (the refuting skeptics keep citing the same
      unresolved gaps, verbatim), further iteration is futile; the gate stops
      re-prompting rather than burn the run cap on a stuck loop.

  ## Usage (wired by the loop — see the module doc of `react_loop.ex` call
  site for the exact hook; this module intentionally does not touch
  `react_loop.ex` itself)

      if GoalVerifier.needs_verification?(state) do
        case GoalVerifier.check(state) do
          {:pass, state} -> ...       # majority did not refute — let the turn finish
          {:gate, directive, state} -> ... # inject directive, loop again
        end
      end

  `check/1` is the single entry point recommended for the loop; `verify/1` and
  `build_directive/2` are exposed separately for tests and for callers that
  want to inspect the raw `Result` before deciding how to react.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Orchestrator

  @type verdict :: :complete | :incomplete | :off_track

  defmodule Result do
    @moduledoc "Aggregated panel verdict returned by `GoalVerifier.verify/1`."
    @type t :: %__MODULE__{
            verdict: OptimalSystemAgent.Agent.Loop.GoalVerifier.verdict(),
            reason: String.t(),
            refuted_count: non_neg_integer(),
            total: non_neg_integer(),
            gaps: [String.t()]
          }
    defstruct verdict: :incomplete, reason: "", refuted_count: 0, total: 0, gaps: []
  end

  # ── Config (env-overridable, mirrors grok's GROK_GOAL_VERIFIER_N /
  #    GOAL_CLASSIFIER_MAX_RUNS_DEFAULT / GOAL_CLASSIFIER_STALL_THRESHOLD) ──

  @default_skeptic_count 3
  @skeptic_min 1
  @skeptic_max 5

  # Run cap: max goal-verification rounds per turn before the gate steps
  # aside (mirrors VerificationGate's @max_reprompts, but a goal-level round
  # is far more expensive — spawns a subagent panel — so the default is small).
  @max_runs 3

  # Consecutive identical gap fingerprints that trip the stall early-exit.
  @stall_threshold 2

  # Byte cap on the embedded diff sent to each skeptic. Past this the diff is
  # truncated with an explicit marker.
  @diff_max_bytes 256 * 1024

  # Tool inventory available to a skeptic (must stay a subset of ToolExecutor's
  # :read_only tier — enforced again, redundantly, by
  # `Orchestrator.run_read_only_panel/2`).
  @skeptic_tools ~w(file_read file_glob dir_list file_grep file_search
                    code_symbols grep_search list_dir read_file semantic_search)

  # ---------------------------------------------------------------------------
  # Gating
  # ---------------------------------------------------------------------------

  @doc """
  `true` when a goal-verification round should run: the run cap and stall
  early-exit both have budget left, there is an active session, and there is
  actually accumulated work (at least one successful write this session) to
  judge. Never fires on a read-only / purely conversational turn.
  """
  @spec needs_verification?(map()) :: boolean()
  def needs_verification?(state) when is_map(state) do
    session_id = Map.get(state, :session_id)
    runs = Map.get(state, :goal_verifier_runs, 0)

    session_id != nil and
      runs < max_runs() and
      not stalled?(state) and
      has_accumulated_work?(session_id)
  end

  def needs_verification?(_), do: false

  @doc "`true` once the stall early-exit has tripped (two identical gap fingerprints in a row)."
  @spec stalled?(map()) :: boolean()
  def stalled?(state) when is_map(state) do
    Map.get(state, :goal_verifier_stall_count, 0) >= stall_threshold()
  end

  def stalled?(_), do: false

  # ---------------------------------------------------------------------------
  # Single entry point recommended for the loop
  # ---------------------------------------------------------------------------

  @doc """
  Run one goal-verification round and decide whether the turn may finish.

  Returns:

    * `{:pass, state}` — majority-did-not-refute (`:complete`); the caller
      should let the turn finish normally (same as if this stage were
      absent).
    * `{:gate, directive, state}` — `:incomplete` or `:off_track`; the caller
      should append `directive` (a `system` message) to `state.messages` and
      loop again, exactly like `VerificationGate.build_directive/1`'s
      contract.

  `state` returned in both cases carries the incremented run counter and the
  updated stall fingerprint — always thread it back into the loop.
  """
  @spec check(map()) :: {:pass, map()} | {:gate, map(), map()}
  def check(state) when is_map(state) do
    {result, state} = verify(state)

    case result.verdict do
      :complete ->
        {:pass, state}

      _ ->
        {directive, state} = build_directive(result, state)
        {:gate, directive, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Panel run
  # ---------------------------------------------------------------------------

  @doc """
  Spawn the skeptic panel, aggregate the verdicts, and advance the run-cap /
  stall-fingerprint counters on `state`.

  Safe to call directly (bypassing `check/1`) when a caller wants the raw
  `Result` — e.g. to log it or fold it into telemetry — before deciding how
  to react.
  """
  @spec verify(map()) :: {Result.t(), map()}
  def verify(state) when is_map(state) do
    session_id = Map.get(state, :session_id)
    runs = Map.get(state, :goal_verifier_runs, 0)
    goal = resolve_goal(state)
    diff = capture_diff(state)

    skeptic_results = spawn_panel(session_id, goal, diff, state)
    {refuted_count, total, verdict, reason, gaps} = aggregate(skeptic_results)

    fingerprint = fingerprint(skeptic_results)
    {stall_count, _} = advance_stall(state, fingerprint, verdict)

    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: session_id,
      round: runs + 1,
      max_runs: max_runs(),
      verdict: verdict,
      refuted_count: refuted_count,
      total: total,
      stall_count: stall_count
    })

    Logger.info(
      "[goal-verifier] round #{runs + 1}/#{max_runs()} session=#{inspect(session_id)} " <>
        "verdict=#{verdict} refuted=#{refuted_count}/#{total} stall=#{stall_count}"
    )

    result = %Result{
      verdict: verdict,
      reason: reason,
      refuted_count: refuted_count,
      total: total,
      gaps: gaps
    }

    state =
      state
      |> Map.put(:goal_verifier_runs, runs + 1)
      |> Map.put(:goal_verifier_last_fingerprint, fingerprint)
      |> Map.put(:goal_verifier_stall_count, stall_count)

    {result, state}
  end

  @doc """
  Build the steer-nudge directive for an `:incomplete` or `:off_track`
  verdict, and advance `state.goal_verifier_prompts` (parallel to
  `VerificationGate.build_directive/1`'s `verification_gate_prompts`).

  `:off_track` produces a redirect nudge ("reconsider the approach / ask for
  clarification") rather than an `:incomplete` "keep going" nudge — the panel
  judged the goal unachievable as currently framed, not merely unfinished.
  """
  @spec build_directive(Result.t(), map()) :: {map(), map()}
  def build_directive(%Result{} = result, state) when is_map(state) do
    prompts = Map.get(state, :goal_verifier_prompts, 0)
    step = prompts + 1

    gaps_block =
      case result.gaps do
        [] -> "  (skeptics gave no structured findings — treat as a general re-check.)"
        gaps -> Enum.map_join(gaps, "\n", &"  - #{&1}")
      end

    content =
      case result.verdict do
        :off_track ->
          "[GOAL VERIFIER: OFF-TRACK — independent skeptic panel #{step}] " <>
            "#{result.refuted_count}/#{result.total} independent read-only reviewers judged this " <>
            "goal NOT achievable as currently approached (not merely unfinished):\n" <>
            gaps_block <>
            "\nDo NOT keep repeating the same approach. Re-read the goal, reconsider your plan, and " <>
            "either take a materially different approach or clearly explain to the user why the goal " <>
            "cannot be met as stated."

        _incomplete ->
          "[GOAL VERIFIER — independent skeptic panel #{step}/#{max_runs()}] " <>
            "#{result.refuted_count}/#{result.total} independent read-only reviewers (fresh context, " <>
            "no access to how this was produced) judged the user's goal NOT yet met:\n" <>
            gaps_block <>
            "\nA passing build/test is necessary but not sufficient — these reviewers checked the " <>
            "change against the GOAL, not just whether it compiles. Address the gap(s) above before " <>
            "declaring the task done."
      end

    directive = %{role: "system", content: content}

    {directive, Map.put(state, :goal_verifier_prompts, step)}
  end

  # ---------------------------------------------------------------------------
  # Panel spawn
  # ---------------------------------------------------------------------------

  defp spawn_panel(session_id, goal, diff, state) do
    n = skeptic_count()
    working_dir = Map.get(state, :working_dir)
    delegation_depth = Map.get(state, :delegation_depth, 0)

    configs =
      for idx <- 0..(n - 1) do
        %{
          task: skeptic_prompt(goal, diff, idx),
          role: "goal-verifier-skeptic",
          name: "goal-skeptic-#{idx}",
          tier: :specialist,
          permission_tier: :read_only,
          tools_allowed: @skeptic_tools,
          tools_blocked: [],
          working_dir: working_dir,
          max_iterations: 6,
          delegation_depth: delegation_depth
        }
      end

    panel_runner().(session_id, configs)
    |> Enum.map(&parse_skeptic_result/1)
  rescue
    e ->
      Logger.warning("[goal-verifier] panel spawn raised: #{Exception.message(e)}")
      # Fail-closed: a panel that could not run at all is treated as a single
      # synthetic refute so a crashed panel can never silently pass the goal.
      [%{refuted: true, off_track: false, reason: "panel spawn failed: #{Exception.message(e)}"}]
  catch
    :exit, reason ->
      Logger.warning("[goal-verifier] panel spawn exited: #{inspect(reason)}")
      [%{refuted: true, off_track: false, reason: "panel spawn exited: #{inspect(reason)}"}]
  end

  # Injectable for tests: `Application.put_env(:optimal_system_agent,
  # :goal_verifier_panel_runner, fn session_id, configs -> [...] end)`.
  # Production default spawns via `Orchestrator.run_read_only_panel/2`, which
  # itself force-locks every config to the read-only tier/tool set.
  defp panel_runner do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_panel_runner,
      &Orchestrator.run_read_only_panel/2
    )
  end

  defp skeptic_prompt(goal, diff, idx) do
    """
    You are an ADVERSARIAL, INDEPENDENT reviewer (skeptic ##{idx}) with NO access to how this \
    change was produced. Your job is to try to REFUTE the claim that the goal below was fully \
    achieved. You are READ-ONLY: you may inspect the repository (file_read / grep_search / \
    dir_list / file_glob / code_symbols) but you must NOT and CANNOT modify anything.

    Default to NOT-REFUTED only if you are genuinely confident the goal is met. If you are \
    uncertain, REFUTE — the cost of a false "not refuted" is much higher than the cost of one \
    more review round.

    ## Goal

    #{goal}

    ## Accumulated diff (working tree vs. last commit, may be truncated)

    ```diff
    #{diff}
    ```

    ## Your task

    1. Read the diff. For anything unclear or that needs corroboration, use your read-only tools \
       to inspect the actual repository state (the diff can lie about context; the files cannot).
    2. Decide: does this diff, as it stands, fully achieve the stated goal? Consider correctness, \
       completeness (not just "a file changed" — did it change the RIGHT thing, and is anything \
       obviously still missing?), and whether the goal is even achievable given what you can see \
       in this repository.
    3. Reply with EXACTLY one JSON object on its own line, and nothing else after it:

       {"refuted": true|false, "off_track": true|false, "reason": "one sentence, cite a concrete gap or confirmation"}

       - "refuted": true means you found a concrete reason the goal is NOT fully met.
       - "off_track": true means (only when refuted) the goal looks unachievable as currently \
         framed (contradiction, missing prerequisite, wrong approach) rather than simply \
         unfinished. Leave it false for an ordinary "not done yet" gap.
    """
  end

  # ---------------------------------------------------------------------------
  # Aggregation (majority-refute)
  # ---------------------------------------------------------------------------

  # A strict majority of the FULL panel must refute for the round to reject
  # (mirrors grok's majority-refute: a lone outlier in either direction cannot
  # decide the outcome). Ties survive as `:complete` only when the majority
  # requirement is not met — i.e. exactly half a panel does NOT reject.
  defp aggregate([]) do
    {0, 0, :incomplete, "no skeptic votes returned (fail-closed)", []}
  end

  defp aggregate(results) do
    total = length(results)
    refuters = Enum.filter(results, & &1.refuted)
    refuted_count = length(refuters)
    needed = div(total, 2) + 1

    cond do
      refuted_count >= needed and majority_off_track?(refuters, needed) ->
        {refuted_count, total, :off_track, off_track_reason(refuters), gap_list(refuters)}

      refuted_count >= needed ->
        {refuted_count, total, :incomplete, incomplete_reason(refuted_count, total),
         gap_list(refuters)}

      true ->
        {refuted_count, total, :complete,
         "#{total - refuted_count}/#{total} skeptics found the goal met", []}
    end
  end

  defp majority_off_track?(refuters, needed) do
    Enum.count(refuters, & &1.off_track) >= needed
  end

  defp off_track_reason(refuters) do
    "majority of refuting skeptics judged the goal unachievable as framed: " <>
      Enum.map_join(refuters, " | ", & &1.reason)
  end

  defp incomplete_reason(refuted_count, total) do
    "#{refuted_count}/#{total} skeptics refuted goal completion"
  end

  defp gap_list(refuters), do: Enum.map(refuters, & &1.reason)

  # Stable fingerprint of the CURRENT refuting gaps, used by the stall
  # early-exit: two consecutive rounds citing the exact same gap set means
  # further iteration is not making progress.
  defp fingerprint(results) do
    results
    |> Enum.filter(& &1.refuted)
    |> Enum.map(&normalize_reason(&1.reason))
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp normalize_reason(reason) when is_binary(reason), do: String.downcase(String.trim(reason))
  defp normalize_reason(_), do: ""

  # `count` tracks consecutive occurrences (in a row) of the CURRENT gap
  # fingerprint, starting at 1 the first time it's seen. Stall trips once
  # `count >= stall_threshold()` — i.e. `@stall_threshold = 2` trips on the
  # SECOND consecutive round citing the identical gap set ("two in a row"),
  # matching grok's `GOAL_CLASSIFIER_STALL_THRESHOLD` semantics.
  defp advance_stall(state, fingerprint, verdict) do
    last = Map.get(state, :goal_verifier_last_fingerprint)
    prev_count = Map.get(state, :goal_verifier_stall_count, 0)

    cond do
      verdict == :complete ->
        {0, false}

      last != nil and last == fingerprint ->
        count = prev_count + 1
        {count, count >= stall_threshold()}

      true ->
        {1, 1 >= stall_threshold()}
    end
  end

  # ---------------------------------------------------------------------------
  # Skeptic response parsing (JSON, with fail-closed fallback)
  # ---------------------------------------------------------------------------

  defp parse_skeptic_result({:ok, response}) when is_binary(response) do
    case extract_json(response) do
      {:ok, %{"refuted" => refuted} = json} when is_boolean(refuted) ->
        %{
          refuted: refuted,
          off_track: Map.get(json, "off_track", false) == true,
          reason: Map.get(json, "reason", "(no reason given)") |> to_string()
        }

      _ ->
        fallback_parse(response)
    end
  end

  defp parse_skeptic_result({:error, reason}) do
    # A skeptic that failed to run at all (crashed / timed out) cannot vouch
    # for completion — count it as a refute, same as a malformed verdict.
    %{refuted: true, off_track: false, reason: "skeptic failed: #{inspect(reason)}"}
  end

  defp parse_skeptic_result(other) do
    %{refuted: true, off_track: false, reason: "unrecognized skeptic result: #{inspect(other)}"}
  end

  # Find the first JSON object in the response text (models often wrap it in
  # prose or a code fence despite instructions).
  defp extract_json(text) do
    case Regex.run(~r/\{[^{}]*"refuted"[^{}]*\}/s, text) do
      [json_str] -> Jason.decode(json_str)
      nil -> :error
    end
  rescue
    _ -> :error
  end

  # Terminal-token fallback (mirrors grok's non-JSON fallback): look for an
  # explicit REFUTED / NOT_REFUTED token; anything else defaults to refuted
  # (fail-closed — "default to not-complete if uncertain").
  defp fallback_parse(text) do
    down = String.downcase(text)

    cond do
      String.contains?(down, "off_track") or String.contains?(down, "off-track") ->
        %{refuted: true, off_track: true, reason: String.slice(text, 0, 240)}

      String.contains?(down, "not_refuted") or String.contains?(down, "not refuted") ->
        %{refuted: false, off_track: false, reason: String.slice(text, 0, 240)}

      String.contains?(down, "refuted") ->
        %{refuted: true, off_track: false, reason: String.slice(text, 0, 240)}

      true ->
        %{
          refuted: true,
          off_track: false,
          reason: "unparsable skeptic response (fail-closed): #{String.slice(text, 0, 200)}"
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Goal / diff sourcing
  # ---------------------------------------------------------------------------

  # Reuses ProgressLedger (read-only) as the primary goal source, since it is
  # the durable, agent-maintained statement of what the session is trying to
  # accomplish. Falls back to the first user message when no ledger goal has
  # been set yet.
  defp resolve_goal(state) do
    session_id = Map.get(state, :session_id)

    ledger_goal =
      case session_id && ProgressLedger.summarize(session_id) do
        {:ok, summary} -> extract_ledger_goal(summary)
        _ -> nil
      end

    case ledger_goal do
      goal when is_binary(goal) and goal != "" and goal != "_Not set._" -> goal
      _ -> first_user_message(state) || "(no explicit goal captured for this session)"
    end
  end

  defp extract_ledger_goal(summary) do
    case Regex.run(~r/Goal:\s*(.*)/, summary) do
      [_, goal] -> String.trim(goal)
      _ -> nil
    end
  end

  defp first_user_message(state) do
    state
    |> Map.get(:messages, [])
    |> Enum.find(fn m -> message_role(m) == "user" end)
    |> case do
      %{content: content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp message_role(%{role: role}), do: to_string(role)
  defp message_role(_), do: nil

  # Working-tree diff vs. HEAD (staged + unstaged), truncated to the byte cap.
  # `git diff HEAD` degrades gracefully (falls back to `git diff`) for a repo
  # with no commits yet.
  defp capture_diff(state) do
    cwd = Map.get(state, :working_dir) || File.cwd!()

    diff =
      case System.cmd("git", ["diff", "HEAD"], cd: cwd, stderr_to_stdout: true) do
        {output, 0} -> output
        _ -> git_diff_fallback(cwd)
      end

    changed = String.trim(diff)

    cond do
      changed == "" ->
        "(no unstaged/staged changes against HEAD — check for committed changes via " <>
          "file_read / grep_search if the goal implies a commit was made)"

      byte_size(changed) > diff_max_bytes() ->
        String.slice(changed, 0, diff_max_bytes()) <>
          "\n... [diff truncated at #{diff_max_bytes()} bytes]"

      true ->
        changed
    end
  end

  defp git_diff_fallback(cwd) do
    case System.cmd("git", ["diff"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {err, _} -> "(git diff unavailable: #{String.slice(err, 0, 200)})"
    end
  rescue
    _ -> "(git diff unavailable)"
  end

  # `true` when the session has at least one successful write on record —
  # the cheap, local precondition checked BEFORE ever spawning the (expensive)
  # skeptic panel.
  defp has_accumulated_work?(session_id) do
    Enum.any?(VerificationEvidence.entries(session_id), fn e ->
      Map.get(e, :kind) == :write and Map.get(e, :success) == true
    end)
  end

  # ---------------------------------------------------------------------------
  # Env-overridable knobs
  # ---------------------------------------------------------------------------

  defp skeptic_count do
    :optimal_system_agent
    |> Application.get_env(:goal_verifier_skeptic_count, @default_skeptic_count)
    |> max(@skeptic_min)
    |> min(@skeptic_max)
  end

  defp max_runs do
    Application.get_env(:optimal_system_agent, :goal_verifier_max_runs, @max_runs)
  end

  defp stall_threshold do
    Application.get_env(:optimal_system_agent, :goal_verifier_stall_threshold, @stall_threshold)
  end

  defp diff_max_bytes do
    Application.get_env(:optimal_system_agent, :goal_verifier_diff_max_bytes, @diff_max_bytes)
  end
end
