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

  ## Budget discipline — the three-tier gate

  The panel is EXPENSIVE (N fresh subagent sessions) and must be unreachable
  except through cheaper stages that decided it was warranted. Three tiers,
  cheapest first:

    * **Tier 0 — free, pure-local** (`skip_reason/1`). No session, no
      accumulated write, run cap spent, stalled, no goal anywhere, or a
      trivial turn (`trivial_turn?/1`). Costs nothing and short-circuits the
      common interactive turn entirely.
    * **Tier 1 — one cheap call** (`triage/1`). A low-token, zero-temperature,
      hard-timeout classification returning `continue | candidate_complete |
      blocked`, ported from grok-build's `goal_evaluator.rs`. `:continue` and
      `:blocked` both stop here; only `:candidate_complete` may proceed. A
      `:blocked` verdict carries a stable `blocker_key`, and the SAME key for
      `@blocker_streak_threshold` consecutive rounds auto-pauses the goal loop
      instead of spinning (identical to Codex's "`blocked` only after the same
      blocker repeats 3 consecutive turns").
    * **Tier 2 — the panel** (`verify/1`). Reached only from
      `:candidate_complete`.

  `maybe_gate/1` is the single entry point that runs all three in order; the
  loop calls it at the TOOL-RESULT boundary (see `react_loop.ex`'s
  `continue_after_tools/4`) so verification always precedes the model's
  conclusion rather than re-entering after one was already presented.

  Two further circuit breakers bound tier 2 once it is reached:

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

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Agent.PermissionMode
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @type verdict :: :complete | :incomplete | :off_track
  @type triage :: :continue | :candidate_complete | :blocked

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

  # Iteration count past which a single turn is treated as long-running, so
  # goal verification auto-activates even in ask mode (mirrors config default;
  # env-overridable). A short two-step edit never reaches this.
  @default_activate_after_iterations 12

  # Byte cap on the embedded diff sent to each skeptic. Past this the diff is
  # truncated with an explicit marker.
  @diff_max_bytes 256 * 1024

  # Wall-clock bound for a SINGLE skeptic (env-overridable via
  # `:goal_verifier_skeptic_timeout_ms`). See `panel_runner/0` for why the
  # generic subagent backstop is the wrong bound here.
  @default_skeptic_timeout_ms 120_000

  # Tool inventory available to a skeptic (must stay a subset of ToolExecutor's
  # :read_only tier — enforced again, redundantly, by
  # `Orchestrator.run_read_only_panel/2`).
  @skeptic_tools ~w(file_read file_glob dir_list file_grep file_search
                    code_symbols grep_search list_dir read_file semantic_search)

  # ---------------------------------------------------------------------------
  # Smart activation
  # ---------------------------------------------------------------------------

  @doc """
  Whether the goal-level skeptic panel is active for this turn.

  Resolution precedence (highest first — operator override always wins):

    1. explicit `config :optimal_system_agent, goal_verifier_enabled: true` or
       `false` — returned verbatim regardless of posture.
    2. `:auto` (the default) — ON when the turn is autonomous/long-running,
       per `autonomous_posture?/1`; OFF otherwise (the common short
       interactive turn).

  This replaces the old blanket off-by-default: finishing-correctly matters
  for autonomous/long work, so verification turns itself on there, while a
  cheap two-step interactive edit never pays for a skeptic panel. The
  reverify-after cadence (`GoalTracker.reverify_due?/1`) and the per-turn run
  cap / stall early-exit still apply on top of this, so "active" does not mean
  "runs every iteration".
  """
  @spec activated?(map()) :: boolean()
  def activated?(state) when is_map(state) do
    case Application.get_env(:optimal_system_agent, :goal_verifier_enabled, :auto) do
      true -> true
      false -> false
      _auto -> autonomous_posture?(state)
    end
  end

  def activated?(_), do: false

  @doc """
  The shared smart-activation predicate: `true` when this turn is autonomous
  or long-running enough that finishing-correctly is worth a verification
  round. Shared by `activated?/1` and `GoalTracker.enabled?/1` so both stages
  auto-activate under exactly the same conditions.

  ON when ANY of:

    * autonomous permission mode — `:overdrive`/`:bypass` on the live state
      or the sticky `PermissionMode` store for the session;
    * an anchored goal loop — `GoalTracker.start/2` set a real goal that is
      still live (`GoalTracker.goal_loop?/1`);
    * a long turn — the current turn has run at least
      `goal_verifier_activate_after_iterations` ReAct iterations.
  """
  @spec autonomous_posture?(map()) :: boolean()
  def autonomous_posture?(state) when is_map(state) do
    autonomous_mode?(state) or goal_loop?(state) or long_turn?(state)
  end

  def autonomous_posture?(_), do: false

  defp autonomous_mode?(state) do
    case Map.get(state, :permission_mode) do
      mode when mode in [:overdrive, :bypass] ->
        true

      _ ->
        sid = Map.get(state, :session_id)
        is_binary(sid) and PermissionMode.overdrive?(sid)
    end
  end

  defp goal_loop?(state) do
    sid = Map.get(state, :session_id)
    is_binary(sid) and GoalTracker.goal_loop?(sid)
  end

  defp long_turn?(state) do
    Map.get(state, :iteration, 0) >= activate_after_iterations()
  end

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
  # Cheap triage gate (grok `goal_evaluator.rs` parity)
  # ---------------------------------------------------------------------------
  #
  # THE MISSING KEYSTONE. Previously `check/1`/`verify/1` were the only entry
  # points and the expensive adversarial panel ran UNCONDITIONALLY whenever the
  # local preconditions held — three read-only subagents, each a full LLM
  # session, on every eligible boundary including a one-file config edit.
  #
  # grok-build never does that: `goal_evaluator.rs` is a ~30s SINGLE cheap call
  # returning `continue | candidate_complete | blocked`, and ONLY
  # `candidate_complete` is allowed to reach the expensive panel. OSA had ported
  # the panel and not the gate. This section is the gate.
  #
  # Three tiers, cheapest first — each must pass before the next is paid for:
  #
  #   Tier 0 (free, pure-local)  — `skip_reason/1`: no session, no accumulated
  #     work, run cap exhausted, stalled, no goal anywhere, or a trivial turn.
  #   Tier 1 (~1 short call)     — `triage/1`: one low-token, tightly-timed
  #     classification call. `:continue` and `:blocked` both stop here.
  #   Tier 2 (N subagents)       — `verify/1`: the adversarial skeptic panel,
  #     reached ONLY on `:candidate_complete`.

  # A turn shorter than this (in ReAct iterations) is a pure question / one-shot
  # answer — nothing an adversarial panel could usefully judge.
  @trivial_max_iterations 2

  # A turn that produced at most this many successful writes is a trivial edit
  # (the observed pathology: installing an MCP server = ONE JSON config write).
  @trivial_max_writes 1

  # Consecutive triage rounds citing the SAME `blocker_key` before the loop
  # auto-pauses instead of spinning. grok uses this; Codex uses the identical
  # rule ("`blocked` only after the same blocker repeats 3 consecutive turns").
  @blocker_streak_threshold 3

  # Bounds on the triage call itself. It must stay CHEAP or it is just a second
  # tax on top of the panel: low token cap, zero temperature, hard wall clock.
  @default_triage_timeout_ms 30_000
  @default_triage_max_tokens 200

  @doc """
  The single gate the loop calls. Runs the cheapest sufficient tier and returns
  the (possibly directive-augmented) state.

  Called at the TOOL-RESULT boundary — before the model generates its next
  message — never after a response has already been presented to the user. See
  the "one ending" note in `react_loop.ex`'s `continue_after_tools/4`.

  Returns `state`, with at most one `system` directive appended to
  `state.messages` and the run-cap / stall / blocker counters advanced. Never
  raises: any failure degrades to "skip this boundary" (see `triage/1`).
  """
  @spec maybe_gate(map()) :: map()
  def maybe_gate(state) when is_map(state) do
    cond do
      not activated?(state) ->
        state

      Map.get(state, :goal_verifier_paused, false) ->
        state

      (reason = skip_reason(state)) != nil ->
        log_skip(state, reason)
        state

      not GoalTracker.reverify_due?(Map.get(state, :session_id)) ->
        state

      true ->
        run_gate(state)
    end
  end

  def maybe_gate(state), do: state

  defp run_gate(state) do
    case triage(state) do
      {:candidate_complete, _meta} ->
        state = clear_blocker(state)
        {result, state} = verify(state)
        GoalTracker.advance(Map.get(state, :session_id), result)

        case result.verdict do
          :complete ->
            state

          _ ->
            {directive, state} = build_directive(result, state)
            append_directive(state, directive)
        end

      {:blocked, meta} ->
        handle_blocked(state, meta)

      {:continue, _meta} ->
        clear_blocker(state)

      # Triage could not be classified at all. FAIL-OPEN (skip the panel), and
      # deliberately so — see `triage/1`'s moduledoc note.
      {:error, reason} ->
        Logger.info("[goal-verifier] triage unavailable (#{inspect(reason)}) — deferring panel")

        Bus.emit(:system_event, %{
          event: :goal_verifier_triage,
          session_id: Map.get(state, :session_id),
          status: :error,
          reason: to_string(inspect(reason))
        })

        state
    end
  end

  @doc """
  Pure-local, zero-cost skip decision. Returns `nil` when this boundary is
  worth spending a triage call on, or the reason atom to skip.

  Skip conditions (each is a turn that obviously cannot benefit from an
  adversarial goal panel):

    * `:no_session`  — no session id to verify against.
    * `:no_work`     — no successful write on record this session. A read-only
      or purely conversational turn produced nothing to refute.
    * `:run_cap`     — the per-turn goal-verification round cap is spent.
    * `:stalled`     — the stall early-exit already tripped.
    * `:no_goal`     — no goal anywhere (no `ProgressLedger` goal, no anchored
      `GoalTracker` goal). Without a goal the panel would be judging the work
      against a guess at the first user message — expensive and meaningless.
    * `:trivial`     — a trivial turn, per `trivial_turn?/1`.
  """
  @spec skip_reason(map()) :: atom() | nil
  def skip_reason(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    cond do
      session_id == nil -> :no_session
      Map.get(state, :goal_verifier_runs, 0) >= max_runs() -> :run_cap
      stalled?(state) -> :stalled
      not has_accumulated_work?(session_id) -> :no_work
      not has_goal?(state) -> :no_goal
      trivial_turn?(state) -> :trivial
      true -> nil
    end
  end

  def skip_reason(_), do: :no_session

  @doc """
  `true` for a turn too small to be worth ANY verification spend.

  Triviality is about SIZE, not about whether a goal is anchored — a goal can
  be "install the MCP server", which is one JSON write and needs no panel. A
  long turn (past `goal_verifier_activate_after_iterations`) is never trivial;
  that escape is what keeps a genuinely complex turn on the full-verification
  path even if it happens to concentrate its edits in one file.

  Otherwise trivial when EITHER:

    * the turn ran at most `@trivial_max_iterations` ReAct iterations — a pure
      question answered in one round; or
    * the session has at most `@trivial_max_writes` successful write(s) — a
      single-file edit. This is the observed pathology: an MCP-server install
      is one JSON config write and paid for a full skeptic panel.
  """
  @spec trivial_turn?(map()) :: boolean()
  def trivial_turn?(state) when is_map(state) do
    cond do
      Map.get(state, :iteration, 0) >= activate_after_iterations() -> false
      Map.get(state, :iteration, 0) <= trivial_max_iterations() -> true
      write_count(Map.get(state, :session_id)) <= trivial_max_writes() -> true
      true -> false
    end
  end

  def trivial_turn?(_), do: true

  @doc """
  The cheap triage call. ONE low-token, zero-temperature, hard-timeout
  classification that decides whether the expensive panel is warranted.

  Returns `{:continue | :candidate_complete | :blocked, meta}` or
  `{:error, reason}`.

  ## Fail-open, and why that is not weakening correctness

  A triage that cannot run degrades to SKIP, not to "run the panel". The
  triage call goes to the same provider that just drove the turn, so a triage
  failure means that provider is unhealthy — in which case every skeptic would
  also fail, and a fail-closed panel of failures is a synthetic
  majority-refute, i.e. an `:incomplete` gate that loops the agent for no
  information at 3× the cost. Skipping does NOT assert completion: the
  `GoalTracker` "verified" state is left untouched, so `reverify_due?/1` still
  fires at the next boundary and the panel's own fail-closed vote semantics are
  unchanged wherever the panel actually runs. The gate defers; it never passes.

  Injectable for tests via `:goal_verifier_triage_runner` —
  `fn state -> {:ok, raw_text} | {:error, reason} end`.
  """
  @spec triage(map()) :: {triage(), map()} | {:error, term()}
  def triage(state) when is_map(state) do
    case call_triage(state) do
      {:ok, raw} when is_binary(raw) -> parse_triage(raw)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_triage_result, other}}
    end
  end

  def triage(_), do: {:error, :no_state}

  defp call_triage(state) do
    runner =
      Application.get_env(:optimal_system_agent, :goal_verifier_triage_runner, &default_triage/1)

    # The runner is rescued INSIDE the task: `Task.async` links, so an
    # unrescued raise in the triage call would take the whole agent loop down
    # with it. A cost gate must never be able to kill the turn it is gating.
    task =
      Task.async(fn ->
        try do
          runner.(state)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, triage_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp default_triage(state) do
    opts = [
      max_tokens: triage_max_tokens(),
      temperature: 0.0,
      # Low reasoning effort: this is a classification, not an analysis. Providers
      # that don't understand the key ignore it.
      reasoning_effort: :low
    ]

    case Providers.chat(triage_messages(state), opts) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, other} -> {:error, {:empty_triage_response, inspect(other)}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, inspect(other)}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The exact message list the triage call sends. Public (but undocumented) so
  # its COST is directly assertable — the whole point of this tier is that it
  # stays small, and in particular that it never carries the diff (that is the
  # panel's job). See the cost-ceiling assertion in goal_verifier_test.exs.
  @doc false
  @spec triage_messages(map()) :: [map()]
  def triage_messages(state) when is_map(state) do
    [
      %{role: "system", content: triage_system_prompt()},
      %{role: "user", content: triage_user_prompt(state)}
    ]
  end

  defp triage_system_prompt do
    """
    You are a fast, cheap TRIAGE classifier inside an autonomous coding agent. \
    You do NOT review the work for correctness — a separate, expensive adversarial \
    panel does that, and your only job is to decide whether that panel is worth \
    spending. Answer in one JSON object and nothing else.

        {"status": "continue" | "candidate_complete" | "blocked", "reason": "<one short sentence>", "blocker_key": "<stable_snake_case_id_or_empty>"}

      - "continue": the agent is still mid-work on the goal. There is obviously \
        more to do. This is the DEFAULT and the cheapest answer — prefer it \
        whenever work plainly remains.
      - "candidate_complete": the agent appears to have finished everything the \
        goal asked for. Only this status triggers the expensive review, so use it \
        when the work looks done and a rigorous check is genuinely warranted.
      - "blocked": progress is stuck on something the agent cannot resolve by \
        itself (a missing credential, an unavailable service, a contradictory \
        requirement, a needed user decision). When and only when you answer \
        "blocked", set "blocker_key" to a SHORT, STABLE snake_case identifier for \
        the blocking reason (e.g. "missing_api_key", "port_in_use", \
        "ambiguous_requirement"). The SAME underlying blocker must produce the \
        SAME key every time you see it — the key is compared across rounds, so do \
        not reword it.

    Output the JSON object only. No prose, no markdown fence.
    """
  end

  # A deliberately COMPACT digest — the triage call must stay cheap, so it never
  # gets the diff (that is the panel's job) and never gets the full transcript.
  @triage_goal_bytes 1_500
  @triage_tail_bytes 1_200

  defp triage_user_prompt(state) do
    session_id = Map.get(state, :session_id)

    """
    ## Goal

    #{truncate(resolve_goal(state), @triage_goal_bytes)}

    ## Progress so far

    - ReAct iterations this turn: #{Map.get(state, :iteration, 0)}
    - Successful writes this session: #{write_count(session_id)}
    - Files touched: #{written_paths(session_id)}

    ## The agent's most recent output

    #{truncate(recent_tail(state), @triage_tail_bytes)}

    Classify. JSON object only.
    """
  end

  # Last assistant text plus the last tool result — enough for "is this done?"
  # without shipping the transcript.
  defp recent_tail(state) do
    state
    |> Map.get(:messages, [])
    |> Enum.reverse()
    |> Enum.filter(&(message_role(&1) in ["assistant", "tool"]))
    |> Enum.take(3)
    |> Enum.reverse()
    |> Enum.map_join("\n\n", fn m ->
      "[#{message_role(m)}] #{content_text(Map.get(m, :content))}"
    end)
    |> case do
      "" -> "(no recent assistant/tool output)"
      text -> text
    end
  end

  defp content_text(c) when is_binary(c), do: c
  defp content_text(c) when is_list(c), do: Enum.map_join(c, " ", &content_text/1)
  defp content_text(%{"text" => t}) when is_binary(t), do: t
  defp content_text(%{text: t}) when is_binary(t), do: t
  defp content_text(other), do: inspect(other)

  defp truncate(text, max) when is_binary(text) do
    if byte_size(text) > max, do: binary_part(text, 0, max) <> "\u{2026}", else: text
  end

  defp truncate(other, max), do: truncate(to_string(other), max)

  # Reuses the panel's already-lenient JSON extraction — the same models produce
  # the same fenced/prose-wrapped output here.
  defp parse_triage(raw) do
    case extract_json(raw) do
      {:ok, json} when is_map(json) ->
        meta = %{
          reason: json_reason(json),
          blocker_key: normalize_blocker_key(Map.get(json, "blocker_key"), json_reason(json))
        }

        case status_atom(Map.get(json, "status")) do
          nil -> fallback_triage(raw, meta)
          status -> {status, meta}
        end

      _ ->
        fallback_triage(raw, %{reason: raw_summary(raw), blocker_key: nil})
    end
  end

  defp status_atom(v) when is_binary(v) do
    case v |> String.downcase() |> String.trim() do
      "continue" -> :continue
      "candidate_complete" -> :candidate_complete
      "candidate-complete" -> :candidate_complete
      "complete" -> :candidate_complete
      "blocked" -> :blocked
      _ -> nil
    end
  end

  defp status_atom(_), do: nil

  # No JSON / no recognizable status. Look for a bare token; failing that, treat
  # it as an error so the caller's fail-open path (defer, don't pass) runs —
  # rather than guessing `candidate_complete` and paying for a panel on noise.
  defp fallback_triage(raw, meta) do
    down = String.downcase(raw)

    cond do
      String.contains?(down, "candidate_complete") -> {:candidate_complete, meta}
      String.contains?(down, "blocked") -> {:blocked, meta}
      String.contains?(down, "continue") -> {:continue, meta}
      true -> {:error, {:unparsable_triage, raw_summary(raw)}}
    end
  end

  # ── blocker_key streak (grok + Codex: 3 consecutive identical blockers) ────

  defp handle_blocked(state, meta) do
    key = meta[:blocker_key] || "unknown_blocker"
    prev = Map.get(state, :goal_verifier_blocker_key)
    streak = if prev == key, do: Map.get(state, :goal_verifier_blocker_streak, 0) + 1, else: 1

    state =
      state
      |> Map.put(:goal_verifier_blocker_key, key)
      |> Map.put(:goal_verifier_blocker_streak, streak)
      |> Map.put_new(:goal_verifier_paused, false)

    Bus.emit(:system_event, %{
      event: :goal_verifier_triage,
      session_id: Map.get(state, :session_id),
      status: :blocked,
      blocker_key: key,
      streak: streak,
      threshold: blocker_streak_threshold()
    })

    if streak >= blocker_streak_threshold() do
      Logger.info(
        "[goal-verifier] blocker #{inspect(key)} repeated #{streak}× — auto-pausing the goal loop"
      )

      directive = %{
        role: "system",
        content:
          "[GOAL VERIFIER: AUTO-PAUSE] The same blocker (`#{key}`) has stopped progress for " <>
            "#{streak} consecutive rounds: #{meta[:reason] || "(no reason given)"}\n" <>
            "Repeating the same approach will not clear it. STOP working the goal now. " <>
            "Explain to the user, in your final answer, exactly what is blocking you and what " <>
            "you need from them (a credential, a decision, an unavailable dependency). Do NOT " <>
            "attempt the same step again."
      }

      state
      |> Map.put(:goal_verifier_paused, true)
      |> append_directive(directive)
    else
      Logger.info(
        "[goal-verifier] triage=blocked key=#{inspect(key)} streak=#{streak}/#{blocker_streak_threshold()}"
      )

      state
    end
  end

  defp clear_blocker(state) do
    state
    |> Map.put(:goal_verifier_blocker_key, nil)
    |> Map.put(:goal_verifier_blocker_streak, 0)
  end

  # Stability is the whole point of the key — normalize aggressively so trivial
  # rewording ("Missing API key" vs "missing_api_key") does not reset the streak.
  defp normalize_blocker_key(key, fallback_reason) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    cond do
      normalized != "" ->
        normalized

      is_binary(fallback_reason) ->
        "reason_" <> to_string(:erlang.phash2(significant_words(fallback_reason)))

      true ->
        "unknown_blocker"
    end
  end

  defp append_directive(state, directive) do
    Map.put(state, :messages, Map.get(state, :messages, []) ++ [directive])
  end

  defp log_skip(state, reason) do
    Logger.debug(
      "[goal-verifier] skipped (#{reason}) session=#{inspect(Map.get(state, :session_id))} " <>
        "iteration=#{Map.get(state, :iteration, 0)}"
    )
  end

  defp has_goal?(state) do
    goal_loop?(state) or ledger_goal(state) != nil
  end

  defp write_entries(session_id) when is_binary(session_id) do
    Enum.filter(VerificationEvidence.entries(session_id), fn e ->
      Map.get(e, :kind) == :write and Map.get(e, :success) == true
    end)
  rescue
    _ -> []
  end

  defp write_entries(_), do: []

  # DISTINCT write TARGETS, not write calls: five edits to one config file is
  # one thing changed, and the trivial-turn test is about how much of the
  # workspace moved. Falls back to the raw entry count when no path was
  # extractable (a write tool whose args the ledger could not parse).
  defp write_count(session_id) do
    entries = write_entries(session_id)

    case written_path_list(entries) do
      [] -> length(entries)
      paths -> length(paths)
    end
  end

  defp written_path_list(entries) do
    entries
    |> Enum.flat_map(fn e -> List.wrap(Map.get(e, :paths)) end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp written_paths(session_id) do
    session_id
    |> write_entries()
    |> written_path_list()
    |> Enum.take(12)
    |> case do
      [] -> "(none recorded)"
      paths -> Enum.join(paths, ", ")
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

    # Lightweight "verifying…" signal so the TUI can show the panel is running
    # WHILE the skeptics spawn (a few seconds). Same sub-event name (so the
    # forwarder allowlist covers it) discriminated by `phase: :start`.
    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: session_id,
      round: runs + 1,
      max_runs: max_runs(),
      phase: :start
    })

    skeptic_results = spawn_panel(session_id, goal, diff, state)
    {refuted_count, total, verdict, reason, gaps} = aggregate(skeptic_results)

    fingerprint = fingerprint(skeptic_results)
    {stall_count, _} = advance_stall(state, fingerprint, verdict)

    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: session_id,
      round: runs + 1,
      max_runs: max_runs(),
      phase: :done,
      verdict: verdict,
      refuted_count: refuted_count,
      total: total,
      stall_count: stall_count,
      # Compact, already lens-tagged gap summary (first two, each truncated) so
      # the TUI can show WHAT is missing without shipping the full findings.
      #
      # Deliberately NOT `result.gaps`: only findings that are genuinely
      # user-meaningful reach the status bar. Harness diagnostics (a skeptic
      # that timed out / crashed) and low-confidence unparsed responses are
      # logged instead — an internal parse failure must never render as a
      # user-facing warning badge.
      gaps: compact_gaps(display_gaps(skeptic_results))
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
            "no access to how this was produced), each applying a distinct lens " <>
            "(correctness / completeness / verifiability), judged the user's goal NOT yet met.\n\n" <>
            "NOT DONE — address these specific gaps now, then continue:\n" <>
            gaps_block <>
            "\n\nA passing build/test is necessary but not sufficient — these reviewers checked the " <>
            "change against the GOAL, not just whether it compiles. Fix exactly the gap(s) above " <>
            "before declaring the task done."
      end

    directive = %{role: "system", content: content}

    {directive, Map.put(state, :goal_verifier_prompts, step)}
  end

  # ---------------------------------------------------------------------------
  # Panel spawn
  # ---------------------------------------------------------------------------

  defp spawn_panel(session_id, goal, diff, state) do
    n = skeptic_count()
    lenses = lenses()
    working_dir = Map.get(state, :working_dir)
    delegation_depth = Map.get(state, :delegation_depth, 0)
    contract = founding_contract(session_id, goal)

    configs =
      for idx <- 0..(n - 1) do
        lens = Enum.at(lenses, rem(idx, length(lenses)))

        %{
          task: skeptic_prompt(goal, diff, idx, lens, contract),
          role: "goal-verifier-skeptic",
          name: "goal-skeptic-#{idx}-#{lens.key}",
          # What this worker IS, for the TUI roster. Without it the orchestrator
          # falls back to the first 80 chars of `:task` — which for a skeptic is
          # the adversarial system prompt, so the roster showed prompt body
          # ("You are an ADVERSARIAL, INDEPENDENT reviewer…") as the agent label.
          description: "skeptic ##{idx + 1} · #{String.downcase(lens.title)}",
          lens: lens.key,
          tier: :specialist,
          permission_tier: :read_only,
          tools_allowed: @skeptic_tools,
          tools_blocked: [],
          working_dir: working_dir,
          max_iterations: 6,
          delegation_depth: delegation_depth
        }
      end

    lens_keys = Enum.map(configs, & &1.lens)

    panel_runner().(session_id, configs)
    |> Enum.map(&parse_skeptic_result/1)
    |> tag_lenses(lens_keys)
  rescue
    e ->
      Logger.warning("[goal-verifier] panel spawn raised: #{Exception.message(e)}")
      # Fail-closed: a panel that could not run at all is treated as a single
      # synthetic refute so a crashed panel can never silently pass the goal.
      # Flagged `internal` — it votes, but it is a harness diagnostic, not a
      # finding, so it never reaches the status bar or the feedback nudge.
      [
        %{
          refuted: true,
          off_track: false,
          reason: "panel spawn failed: #{Exception.message(e)}",
          lens: :panel,
          confidence: :low,
          internal: true
        }
      ]
  catch
    :exit, reason ->
      Logger.warning("[goal-verifier] panel spawn exited: #{inspect(reason)}")

      [
        %{
          refuted: true,
          off_track: false,
          reason: "panel spawn exited: #{inspect(reason)}",
          lens: :panel,
          confidence: :low,
          internal: true
        }
      ]
  end

  # Attach the lens each skeptic was assigned to its parsed verdict, so a
  # refute can name WHICH failure mode (correctness / completeness /
  # verifiability) it came from in the feedback nudge. Only zips when the
  # runner returned one result per config (the normal 1:1 case); a
  # short/long/synthetic list is left untagged (`:unknown`) rather than
  # mis-aligned.
  defp tag_lenses(results, lens_keys) when length(results) == length(lens_keys) do
    results
    |> Enum.zip(lens_keys)
    |> Enum.map(fn {r, lens} -> Map.put(r, :lens, lens) end)
  end

  defp tag_lenses(results, _lens_keys) do
    Enum.map(results, &Map.put_new(&1, :lens, :unknown))
  end

  # Injectable for tests: `Application.put_env(:optimal_system_agent,
  # :goal_verifier_panel_runner, fn session_id, configs -> [...] end)`.
  # Production default spawns via `Orchestrator.run_read_only_panel/3`, which
  # itself force-locks every config to the read-only tier/tool set.
  #
  # The explicit `await_timeout:` is load-bearing. Without it the panel
  # inherits `Orchestrator`'s generic `:subagent_await_timeout_ms` backstop of
  # **two hours**, which is the right bound for a long delegated workstream and
  # badly wrong for a skeptic: a skeptic is a read-only vote capped at 6
  # iterations that BLOCKS the user's turn while the panel is joined, so one
  # wedged skeptic (a stuck provider stream, a retry storm) silently stalls the
  # whole turn behind it. `goal_verifier_skeptic_timeout_ms` gives the stage its
  # own, much tighter bound; a skeptic past it is reaped by `run_parallel` and
  # counted as a fail-closed refute, exactly like a crash.
  defp panel_runner do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_panel_runner,
      fn session_id, configs ->
        Orchestrator.run_read_only_panel(session_id, configs, await_timeout: skeptic_timeout_ms())
      end
    )
  end

  # ── Perspective-diverse skeptic lenses ───────────────────────────────────
  #
  # grok-build runs N IDENTICAL skeptics with the same prompt. We do strictly
  # better: each skeptic gets a DISTINCT lens, so the panel catches three
  # different failure modes instead of triangulating on one. Because a
  # completeness gap and a verifiability gap are independent, a diverse panel
  # is more discerning than N-identical at the same N.
  #
  # The set is a plain data list so it is trivial to extend (add a 4th lens
  # and bump the skeptic count). It scales gracefully for any skeptic_count:
  # lenses are assigned by `rem(idx, length(lenses))`, so 1 skeptic gets
  # correctness, 3 get one each, 5 wrap around (correctness/completeness/
  # verifiability/correctness/completeness).
  #
  # Every lens keeps the SAME anti-over-refusal contract (default NOT-REFUTED
  # on uncertainty, refute only on CONCRETE evidence) and the SAME JSON output
  # shape, so aggregation stays a uniform majority-refute / fail-closed vote —
  # the only thing that differs is WHERE each skeptic is told to look.
  @lenses [
    %{
      key: :correctness,
      title: "CORRECTNESS",
      focus:
        "Focus your scrutiny on CORRECTNESS: does what was produced actually DO what the goal " <>
          "asked, correctly? Look for logic bugs, wrong behavior, off-by-one / boundary errors, " <>
          "mishandled edge cases, and changes that compile but do the wrong thing. A change can " <>
          "be present and still be incorrect — refute only if you can point to a concrete way " <>
          "the produced behavior diverges from what the goal requires."
    },
    %{
      key: :completeness,
      title: "COMPLETENESS",
      focus:
        "Focus your scrutiny on COMPLETENESS: is EVERY part of the request addressed, with " <>
          "nothing silently dropped, stubbed, faked, or left as a TODO/placeholder? Enumerate " <>
          "the distinct requirements implied by the goal and check each one is really " <>
          "implemented (not just referenced). Refute only if you can name a specific requirement " <>
          "that is missing, stubbed, or only partially done."
    },
    %{
      key: :verifiability,
      title: "VERIFIABILITY",
      focus:
        "Focus your scrutiny on VERIFIABILITY / EVIDENCE: is there concrete evidence this " <>
          "actually WORKS, rather than a claim that it works? Would it compile, would the " <>
          "relevant tests pass, is the new behavior demonstrated (a test, a checked output) " <>
          "rather than merely asserted in prose? Refute only if success is claimed but " <>
          "unproven, or you can see a test/build that would fail."
    }
  ]

  # The active lens set (data-driven so it is easy to extend/override).
  defp lenses, do: @lenses

  # The founding request, as recorded by `TaskBrief` when the goal was first
  # anchored — NOT the objective the model is currently working to.
  #
  # This is the single most important input a panel judging a SELF-AUTHORED goal
  # can have, and it is the thing Codex's design does not have at all: there, the
  # completion audit is performed by the same model, in the same turn, against
  # the objective that model wrote. The restatement is the only contract, so a
  # goal narrowed at authoring time is narrowed for every judge that ever sees
  # it.
  #
  # grok-build gets this right and the wording below is theirs
  # (`templates/goal_verifier_prompt.md`): the objective is "the immutable
  # contract", the derived checklist "may clarify but never narrow or override"
  # it, and a self-serving criterion "is itself grounds to refute".
  #
  # Returns "" when there is no brief, or when the brief says nothing the goal
  # text does not already say — in which case there is no second reading to
  # compare against and the extra prompt weight would be noise.
  defp founding_contract(session_id, goal) do
    with true <- is_binary(session_id) and session_id != "",
         {:ok, brief} <- OptimalSystemAgent.Agent.TaskBrief.load(session_id),
         founding <- text(Map.get(brief, :goal)),
         criteria <- text(Map.get(brief, :acceptance_criteria)),
         block when block != "" <- contract_block(founding, criteria, text(goal)) do
      block
    else
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  defp contract_block(founding, criteria, goal) do
    founding_part =
      if founding != "" and founding != goal do
        "\n\n## The founding request (authoritative)\n\n" <>
          founding <>
          "\n\nThe goal stated above is the agent's own restatement of this request. This " <>
          "founding request is the immutable contract: the restatement and any criteria " <>
          "derived from it may clarify it but may never narrow or override it. If the " <>
          "restatement drops, softens, or redefines something this request asked for, that " <>
          "is itself grounds to refute — judge against the request, not against the " <>
          "easier version of it."
      else
        ""
      end

    criteria_part =
      if criteria != "" and criteria != goal and criteria != founding do
        "\n\n## Acceptance criteria recorded at goal creation\n\n" <>
          criteria <>
          "\n\nJudge each criterion met or unmet, but refute any requirement of the founding " <>
          "request that these criteria omit. A criterion is a floor, never a ceiling."
      else
        ""
      end

    founding_part <> criteria_part
  end

  defp text(v) when is_binary(v), do: String.trim(v)
  defp text(_), do: ""

  defp skeptic_prompt(goal, diff, idx, lens, contract) do
    """
    You are an ADVERSARIAL, INDEPENDENT reviewer (skeptic ##{idx}, #{lens.title} lens) with NO \
    access to how this change was produced. Your job is to try to REFUTE the claim that the goal \
    below was fully achieved, viewed specifically through the #{lens.title} lens. You are \
    READ-ONLY: you may inspect the repository (file_read / grep_search / dir_list / file_glob / \
    code_symbols) but you must NOT and CANNOT modify anything.

    ## Your lens

    #{lens.focus}

    Default to NOT-REFUTED when uncertain. Only REFUTE when you have found CONCRETE evidence \
    the goal is unmet (a missing file, a change that contradicts the goal, a test you can see \
    would fail, an unaddressed requirement stated in the goal). Genuine uncertainty or an \
    inability to fully verify from what you can see is NOT itself grounds to refute — say so in \
    "reason" and leave "refuted" false. A false refute costs a full extra review round on work \
    that was already done; only spend that cost when you can point to a specific gap through \
    your lens.

    ## Goal

    #{goal}
    #{contract}

    ## Accumulated diff (working tree vs. last commit, may be truncated)

    ```diff
    #{diff}
    ```

    ## Your task

    1. Read the diff. For anything unclear or that needs corroboration, use your read-only tools \
       to inspect the actual repository state (the diff can lie about context; the files cannot).
    2. Judge the goal THROUGH YOUR #{lens.title} LENS specifically — do not try to re-check every \
       possible angle; other independent reviewers cover the other angles.
    3. Reply with your verdict as a SINGLE JSON object.

    ## Output contract (strict — read this twice)

    Your ENTIRE final message must be exactly one JSON object and nothing else. No prose before \
    it, no prose after it, no markdown code fence, no explanation of your reasoning outside the \
    object. The object has EXACTLY these three fields, all required:

        {"refuted": <boolean>, "off_track": <boolean>, "reason": "<one sentence>"}

      - "refuted" (boolean, required): `true` means you found a concrete reason the goal is NOT \
        fully met. `false` means you did not. Must be a JSON boolean — not "true", not "yes".
      - "off_track" (boolean, required): `true` only when "refuted" is also true AND the goal \
        looks unachievable as currently framed (contradiction, missing prerequisite, wrong \
        approach) rather than simply unfinished. Otherwise `false`.
      - "reason" (string, required): ONE sentence. When refuting, cite the concrete gap \
        (file / symbol / requirement). When not refuting, name what you checked. Keep it under \
        200 characters and do not embed newlines.

    Two valid examples, exactly as they should appear:

        {"refuted": false, "off_track": false, "reason": "the exporter is implemented in lib/widget/exporter.ex and handles the empty-input case"}

        {"refuted": true, "off_track": false, "reason": "lib/widget/exporter.ex writes CSV but the goal asked for JSON output"}
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

  # Each gap is prefixed with the lens that caught it, so the feedback nudge
  # tells the agent WHICH failure mode is unmet (correctness vs completeness
  # vs verifiability) — strictly more actionable than a bare reason.
  #
  # Harness diagnostics (`internal: true` — a skeptic that crashed or timed
  # out) are dropped: they still count as fail-closed refutes in the VOTE, but
  # "skeptic failed: :timeout" is not a gap the agent can act on. A
  # low-confidence raw-text review IS kept — an unstructured review is still
  # information — but is labelled so the agent knows it was not structured.
  defp gap_list(refuters) do
    refuters
    |> Enum.reject(&internal?/1)
    |> Enum.map(&lens_prefixed_reason/1)
  end

  # The strictly narrower projection that may reach the USER (status bar):
  # refuting, non-internal, and confidently parsed. Anything the harness could
  # not read properly is logged, not badged.
  defp display_gaps(results) do
    results
    |> Enum.filter(
      &(&1.refuted and not internal?(&1) and Map.get(&1, :confidence, :high) != :low)
    )
    |> Enum.map(&lens_prefixed_reason/1)
  end

  defp internal?(result), do: Map.get(result, :internal, false) == true

  # A tiny, TUI-sized projection of the gap list for the emitted event: at most
  # the first two lens-tagged gaps, each truncated, so the status indicator can
  # show WHAT is missing without carrying the full findings over the wire.
  @compact_gap_max 2
  @compact_gap_bytes 80
  defp compact_gaps(gaps) when is_list(gaps) do
    gaps
    |> Enum.take(@compact_gap_max)
    |> Enum.map(&truncate_gap/1)
  end

  defp compact_gaps(_), do: []

  defp truncate_gap(gap) when is_binary(gap) do
    if byte_size(gap) > @compact_gap_bytes do
      String.slice(gap, 0, @compact_gap_bytes) <> "\u{2026}"
    else
      gap
    end
  end

  defp truncate_gap(gap), do: to_string(gap)

  defp lens_prefixed_reason(%{reason: reason} = result) do
    lens = Map.get(result, :lens)
    prefix = if lens in [:correctness, :completeness, :verifiability], do: "[#{lens}] ", else: ""

    # A tier-3 (unstructured) review is still fed back, but honestly labelled
    # so the agent weighs it as a free-form note rather than a crisp finding.
    marker =
      if Map.get(result, :confidence, :high) == :low, do: "(unstructured review) ", else: ""

    prefix <> marker <> to_string(reason)
  end

  # Stable fingerprint of the CURRENT refuting gaps, used by the stall
  # early-exit: two consecutive rounds citing the SAME underlying gap set
  # means further iteration is not making progress.
  #
  # Hashing the raw free-form `reason` sentence (finding #10 / D3) never
  # actually trips: skeptics rarely (if ever) produce byte-identical prose
  # across rounds even when describing the exact same unresolved gap, so the
  # fingerprint changes every round and the stall early-exit is effectively
  # dead code — an abandoned goal just re-verifies to the lifetime cap
  # instead of auto-pausing. Fingerprint on a STABLE signal instead: the
  # sorted, deduplicated set of concrete gap identifiers (file paths,
  # module/function names) mentioned across the refuting reasons. The same
  # unresolved gap tends to cite the same file/symbol round after round even
  # when the surrounding sentence is reworded.
  defp fingerprint(results) do
    results
    |> Enum.filter(& &1.refuted)
    |> Enum.flat_map(&gap_identifiers(&1.reason))
    |> Enum.uniq()
    |> Enum.sort()
    |> :erlang.phash2()
  end

  # File paths (e.g. `lib/foo/bar.ex`), dotted module names (`Foo.Bar.Baz`),
  # and snake_case symbols (`goal_verifier_runs`) mentioned in a skeptic's
  # reason — the concrete, reproducible identifiers of WHICH gap is being
  # cited, independent of how the surrounding sentence is phrased.
  @path_re ~r/\b[\w\-]+(?:\/[\w\-]+)+\.\w{1,6}\b/
  @dotted_module_re ~r/\b[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)+\b/
  @snake_symbol_re ~r/\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/

  defp gap_identifiers(reason) when is_binary(reason) do
    down = reason

    identifiers =
      (Regex.scan(@path_re, down) ++
         Regex.scan(@dotted_module_re, down) ++
         Regex.scan(@snake_symbol_re, down))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    cond do
      identifiers != [] ->
        identifiers

      # No concrete identifier cited at all — fall back to a normalized
      # bag-of-significant-words (drops stopwords/short filler) so gaps
      # described only in prose still have a reasonably stable signal
      # instead of collapsing every round to a distinct hash.
      significant_words(down) != [] ->
        significant_words(down)

      true ->
        # Short/terse reason with no extractable identifier AND no word long
        # enough to survive the stopword/length filter (e.g. "gap A" vs
        # "gap B"). Falling through to an empty list here would collapse
        # every such reason to the SAME fingerprint, hiding genuinely
        # different gaps behind a false stall. Last-resort: the normalized
        # whole string, so distinct short reasons still compare distinct.
        [normalize_reason(down)]
    end
  end

  defp gap_identifiers(_), do: []

  defp normalize_reason(reason) when is_binary(reason), do: String.downcase(String.trim(reason))
  defp normalize_reason(_), do: ""

  @stopwords ~w(the a an is are was were be been being this that these those
    and or but not with without from into onto over under for to of in on at
    it its as by has have had does do did goal fully still needs need missing
    unclear cannot doesnt didnt hasnt havent isnt wasnt)

  defp significant_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split()
    |> Enum.filter(&(String.length(&1) > 3 and &1 not in @stopwords))
    |> Enum.uniq()
    |> Enum.sort()
  end

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
  # Skeptic response parsing — LENIENT, three-tier (never errors out)
  # ---------------------------------------------------------------------------
  #
  # A review that cannot be parsed is still information; failing the whole
  # verification (or, worse, surfacing "unparsable skeptic response" to the
  # user as a *gap*) because of formatting is strictly worse than degrading.
  # So parsing always produces a usable verdict, via three tiers:
  #
  #   1. STRICT     — the whole response (fences stripped) is a JSON object.
  #   2. BRACE-SLICE— the outermost `{...}` span in the text, then each
  #      balanced `{...}` candidate, decoded in turn. Models routinely wrap the
  #      object in prose or a ```json fence despite instructions.
  #   3. DEGRADE    — no JSON at all: look for an explicit REFUTED /
  #      NOT_REFUTED token, and failing even that, keep the RAW TEXT as the
  #      explanation and return a valid, `confidence: :low` result. Never an
  #      error, never a synthetic "unparsable…" string masquerading as a
  #      finding.
  #
  # Every parsed result carries two housekeeping keys used by the surfacing
  # layer (see `display_gaps/1`):
  #
  #   * `:confidence` — `:high` (structured JSON), `:medium` (token fallback),
  #     `:low` (tier 3 — raw text kept as the explanation).
  #   * `:internal`   — `true` when the "reason" is a harness diagnostic
  #     (spawn failed, timed out, unrecognized shape) rather than a review
  #     finding. Internal diagnostics are logged, never shown to the user and
  #     never fed back to the model as a "gap".

  defp parse_skeptic_result({:ok, response}) when is_binary(response) do
    case extract_json(response) do
      {:ok, json} when is_map(json) ->
        case coerce_bool(Map.get(json, "refuted")) do
          refuted when is_boolean(refuted) ->
            %{
              refuted: refuted,
              off_track: coerce_bool(Map.get(json, "off_track")) == true,
              reason: json_reason(json),
              confidence: :high,
              internal: false
            }

          _ ->
            fallback_parse(response)
        end

      _ ->
        fallback_parse(response)
    end
  end

  defp parse_skeptic_result({:error, reason}) do
    # A skeptic that failed to run at all (crashed / timed out) cannot vouch
    # for completion — count it as a refute, same as a malformed verdict. The
    # reason is a harness diagnostic, so it is flagged `internal` and never
    # surfaces as a user-facing gap.
    Logger.warning("[goal-verifier] skeptic did not complete: #{inspect(reason)}")

    %{
      refuted: true,
      off_track: false,
      reason: "skeptic failed: #{inspect(reason)}",
      confidence: :low,
      internal: true
    }
  end

  defp parse_skeptic_result(other) do
    Logger.warning("[goal-verifier] unrecognized skeptic result shape: #{inspect(other)}")

    %{
      refuted: true,
      off_track: false,
      reason: "unrecognized skeptic result: #{inspect(other)}",
      confidence: :low,
      internal: true
    }
  end

  # Tiers 1 + 2. Returns `{:ok, map}` or `:error` — never raises.
  defp extract_json(text) when is_binary(text) do
    stripped = strip_fences(text)

    with :error <- decode_map(stripped),
         :error <- brace_slice(stripped),
         :error <- brace_slice(text),
         :error <- balanced_candidates(stripped),
         :error <- balanced_candidates(text) do
      :error
    end
  rescue
    _ -> :error
  end

  defp extract_json(_), do: :error

  # Strip a leading/trailing markdown code fence (```json … ```), which models
  # add roughly as often as they omit it.
  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```[a-zA-Z0-9_-]*\s*\n?/, "")
    |> String.replace(~r/\n?```\s*\z/, "")
    |> String.trim()
  end

  defp decode_map(str) when is_binary(str) do
    case Jason.decode(String.trim(str)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_map(_), do: :error

  # Tier 2a — the OUTERMOST `{...}` span (first `{` through last `}`). Handles
  # the common "prose … {json} … prose" wrapper in one shot.
  defp brace_slice(text) when is_binary(text) do
    with {open, _} <- first_match(text, "{"),
         close when is_integer(close) and close > open <- last_match(text, "}") do
      text |> binary_part(open, close - open + 1) |> decode_map()
    else
      _ -> :error
    end
  end

  defp brace_slice(_), do: :error

  defp first_match(text, pattern) do
    case :binary.match(text, pattern) do
      :nomatch -> nil
      match -> match
    end
  end

  defp last_match(text, pattern) do
    case :binary.matches(text, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # Tier 2b — every balanced `{...}` candidate, innermost-first, preferring the
  # one that actually carries a "refuted" key. Rescues the case where the model
  # emitted several objects (e.g. an example plus the real verdict).
  @max_object_candidates 24

  defp balanced_candidates(text) when is_binary(text) do
    candidates = object_candidates(text)

    Enum.find_value(candidates, fn cand ->
      case decode_map(cand) do
        {:ok, map} -> if Map.has_key?(map, "refuted"), do: {:ok, map}, else: nil
        :error -> nil
      end
    end) ||
      Enum.find_value(candidates, :error, fn cand ->
        case decode_map(cand) do
          {:ok, map} -> {:ok, map}
          :error -> nil
        end
      end)
  end

  defp balanced_candidates(_), do: :error

  defp object_candidates(text) do
    opens = Enum.map(:binary.matches(text, "{"), fn {p, _} -> {p, :open} end)
    closes = Enum.map(:binary.matches(text, "}"), fn {p, _} -> {p, :close} end)

    {objects, _stack} =
      (opens ++ closes)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn
        {p, :open}, {objs, stack} ->
          {objs, [p | stack]}

        {p, :close}, {objs, [open | rest]} ->
          {[binary_part(text, open, p - open + 1) | objs], rest}

        {_p, :close}, {objs, []} ->
          {objs, []}
      end)

    objects |> Enum.reverse() |> Enum.take(@max_object_candidates)
  end

  defp coerce_bool(v) when is_boolean(v), do: v

  defp coerce_bool(v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      s when s in ~w(true yes y 1) -> true
      s when s in ~w(false no n 0) -> false
      _ -> nil
    end
  end

  defp coerce_bool(1), do: true
  defp coerce_bool(0), do: false
  defp coerce_bool(_), do: nil

  # The explanation field, under any of the names a model plausibly picks.
  @reason_keys ~w(reason explanation summary justification rationale detail message)

  defp json_reason(json) do
    Enum.find_value(@reason_keys, "(no reason given)", fn key ->
      case Map.get(json, key) do
        v when is_binary(v) ->
          case String.trim(v) do
            "" -> nil
            trimmed -> trimmed
          end

        v when not is_nil(v) and not is_map(v) and not is_list(v) ->
          to_string(v)

        _ ->
          nil
      end
    end)
  end

  # Tier 3 — no JSON anywhere. Look for an explicit REFUTED / NOT_REFUTED token
  # (mirrors grok's non-JSON fallback); anything else keeps the raw text as the
  # explanation and degrades to a low-confidence, fail-closed refute rather than
  # erroring or fabricating an "unparsable…" finding.
  @raw_reason_max 240

  defp fallback_parse(text) do
    down = String.downcase(text)

    cond do
      String.contains?(down, "off_track") or String.contains?(down, "off-track") ->
        %{
          refuted: true,
          off_track: true,
          reason: raw_summary(text),
          confidence: :medium,
          internal: false
        }

      String.contains?(down, "not_refuted") or String.contains?(down, "not refuted") ->
        %{
          refuted: false,
          off_track: false,
          reason: raw_summary(text),
          confidence: :medium,
          internal: false
        }

      String.contains?(down, "refuted") ->
        %{
          refuted: true,
          off_track: false,
          reason: raw_summary(text),
          confidence: :medium,
          internal: false
        }

      true ->
        # Deliberately NOT surfaced as a gap (see `display_gaps/1`): a
        # formatting failure is an internal detail, not something the user
        # should read off the status bar. Logged so it stays diagnosable.
        Logger.warning(
          "[goal-verifier] skeptic response carried no parseable verdict; degrading to " <>
            "low-confidence fail-closed refute. raw=#{inspect(String.slice(text, 0, 400))}"
        )

        %{
          refuted: true,
          off_track: false,
          reason: raw_summary(text),
          confidence: :low,
          internal: false
        }
    end
  end

  defp raw_summary(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    cond do
      collapsed == "" ->
        "(reviewer returned an empty response)"

      String.length(collapsed) > @raw_reason_max ->
        String.slice(collapsed, 0, @raw_reason_max) <> "\u{2026}"

      true ->
        collapsed
    end
  end

  defp raw_summary(other), do: raw_summary(to_string(other))

  # ---------------------------------------------------------------------------
  # Goal / diff sourcing
  # ---------------------------------------------------------------------------

  # Reuses ProgressLedger (read-only) as the primary goal source, since it is
  # the durable, agent-maintained statement of what the session is trying to
  # accomplish. Falls back to the first user message when no ledger goal has
  # been set yet.
  defp resolve_goal(state) do
    ledger_goal(state) || first_user_message(state) ||
      "(no explicit goal captured for this session)"
  end

  # The DURABLE goal only (no first-user-message fallback) — `skip_reason/1`'s
  # `:no_goal` check must not be satisfied by a guess at the opening message.
  defp ledger_goal(state) do
    session_id = Map.get(state, :session_id)

    goal =
      case session_id && ProgressLedger.summarize(session_id) do
        {:ok, summary} -> extract_ledger_goal(summary)
        _ -> nil
      end

    case goal do
      g when is_binary(g) and g != "" and g != "_Not set._" -> g
      _ -> nil
    end
  rescue
    _ -> nil
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
      case OptimalSystemAgent.Git.cmd(["diff", "HEAD"], cd: cwd, stderr_to_stdout: true) do
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
    case OptimalSystemAgent.Git.cmd(["diff"], cd: cwd, stderr_to_stdout: true) do
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

  defp activate_after_iterations do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_activate_after_iterations,
      @default_activate_after_iterations
    )
  end

  defp skeptic_timeout_ms do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_skeptic_timeout_ms,
      @default_skeptic_timeout_ms
    )
  end

  defp diff_max_bytes do
    Application.get_env(:optimal_system_agent, :goal_verifier_diff_max_bytes, @diff_max_bytes)
  end

  defp trivial_max_iterations do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_trivial_max_iterations,
      @trivial_max_iterations
    )
  end

  defp trivial_max_writes do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_trivial_max_writes,
      @trivial_max_writes
    )
  end

  defp blocker_streak_threshold do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_blocker_streak_threshold,
      @blocker_streak_threshold
    )
  end

  defp triage_timeout_ms do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_triage_timeout_ms,
      @default_triage_timeout_ms
    )
  end

  defp triage_max_tokens do
    Application.get_env(
      :optimal_system_agent,
      :goal_verifier_triage_max_tokens,
      @default_triage_max_tokens
    )
  end
end
