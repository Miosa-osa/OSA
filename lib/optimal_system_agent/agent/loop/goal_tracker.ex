defmodule OptimalSystemAgent.Agent.Loop.GoalTracker do
  @moduledoc """
  Multi-turn goal orchestration — a PERSISTENT, cross-turn goal status
  machine, modeled on grok-build's `session/goal_tracker.rs`
  (`GoalStatus`/`GoalPhase`, `GOAL_CLASSIFIER_STALL_THRESHOLD`) and
  `agent/config.rs` (`resolve_goal_reverify_after`).

  ## Why this exists (P1 gap #4 — multi-turn goal orchestration)

  `Agent.Loop.GoalVerifier` is a strong SINGLE-TURN gate: within one call to
  `ReactLoop.run/1` (i.e. one user message, which may itself contain many
  internal ReAct steps) it spawns an N-skeptic read-only panel and self-gates
  on a per-turn run cap + a per-turn stall fingerprint. But its bookkeeping
  (`state.goal_verifier_runs`, `state.goal_verifier_stall_count`, ...) lives
  in the `state` map threaded through in-process recursion — it is reset to
  zero the instant a NEW top-level turn (a new user message / a new call into
  the loop) begins. There is therefore no memory of "we already tried 6 times
  across the last 6 messages and keep hitting the same gap" — an autonomous
  agent working a long-horizon goal across MANY separate turns can spin
  forever without a global circuit breaker.

  This module is that missing cross-turn layer: a small ETS-backed state
  machine, keyed by `session_id`, that survives across top-level turns (the
  same way `Agent.PermissionMode` and `Agent.Loop.Steer` survive across
  turns) and:

    * tracks a `status` (`:active | :paused | :completed | :off_track`) and a
      `phase` (`:idle | :planning | :executing`) for the goal, persisted
      across turns;
    * detects a STALL across turns — two consecutive goal-verification
      rounds (which may be turns apart) that cite the identical gap
      fingerprint — and auto-pauses (`:paused`, reason `:no_progress`),
      mirroring grok's `GOAL_CLASSIFIER_STALL_THRESHOLD` / `record_classifier_
      stall`;
    * enforces a lifetime RUN CAP across the whole goal (not just one turn)
      before auto-pausing (`:paused`, reason `:run_cap`), mirroring grok's
      `classifier_max_runs`;
    * enforces a REVERIFY-AFTER cadence (`reverify_due?/1`) so the expensive
      skeptic panel is not spawned every single turn — only once every
      `reverify_after` turns (or immediately on the very first turn),
      mirroring `resolve_goal_reverify_after` /
      `GOAL_REVERIFY_AFTER_DEFAULT`;
    * transitions `:active -> :completed` when `GoalVerifier` returns
      `:complete`, `:active -> :off_track` (with a re-plan nudge queued via
      `Agent.Loop.Steer`) when `GoalVerifier` returns `:off_track`, and
      `:active -> :paused` on stall/run-cap;
    * reuses `Agent.ProgressLedger` as the durable goal store — `start/2`
      writes the goal into the ledger's `## Goal` section, and every status
      transition is appended to the ledger's `## Log` so the transition
      history survives a context reset / daemon restart exactly like every
      other durable goal signal in OSA.

  ## Config gate (default OFF)

  Like `GoalVerifier`, this is off by default (`config :optimal_system_agent,
  goal_tracker_enabled: true`, or the session is in an autonomous posture —
  see `enabled?/1`) — it is meant for long autonomous runs, not quick
  interactive edits.

  ## Usage (single entry point recommended for the loop — see the module doc
  at the bottom of this file for the exact `react_loop.ex` hook; this module
  intentionally does not touch `react_loop.ex` itself)

      # once per NEW top-level turn (before running the ReAct loop):
      GoalTracker.tick_turn(session_id)

      # gate the (expensive) goal-verification panel on cadence, in addition
      # to GoalVerifier's own per-turn gating:
      if GoalTracker.reverify_due?(session_id) and GoalVerifier.needs_verification?(state) do
        {result, state} = GoalVerifier.verify(state)
        GoalTracker.advance(session_id, result)
        ...
      end

      # before deciding whether to keep driving the goal autonomously:
      if GoalTracker.continue?(session_id) do
        ...
      else
        # :paused or :completed — surface GoalTracker.snapshot(session_id) and stop
      end
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Events.Bus

  @table :osa_goal_tracker

  @type status :: :active | :paused | :completed | :off_track
  @type phase :: :idle | :planning | :executing
  @type pause_reason :: :no_progress | :run_cap | :off_track | :user | nil

  defmodule Snapshot do
    @moduledoc "Persisted per-session goal-tracker state."
    @type t :: %__MODULE__{
            session_id: String.t(),
            status: OptimalSystemAgent.Agent.Loop.GoalTracker.status(),
            phase: OptimalSystemAgent.Agent.Loop.GoalTracker.phase(),
            goal: String.t() | nil,
            turn_count: non_neg_integer(),
            rounds_since_verify: non_neg_integer(),
            verify_run_count: non_neg_integer(),
            last_gap_fingerprint: integer() | nil,
            stall_count: non_neg_integer(),
            pause_reason: OptimalSystemAgent.Agent.Loop.GoalTracker.pause_reason(),
            history: [String.t()],
            updated_at: DateTime.t() | nil
          }
    defstruct session_id: nil,
              status: :active,
              phase: :executing,
              goal: nil,
              turn_count: 0,
              rounds_since_verify: 0,
              verify_run_count: 0,
              last_gap_fingerprint: nil,
              stall_count: 0,
              pause_reason: nil,
              history: [],
              updated_at: nil
  end

  # ── Config (env-overridable, mirrors grok's GROK_GOAL_CLASSIFIER_MAX /
  #    GROK_GOAL_REVERIFY_AFTER / GOAL_CLASSIFIER_STALL_THRESHOLD) ──

  # Lifetime run cap ACROSS THE WHOLE GOAL (all turns), distinct from
  # GoalVerifier's own smaller PER-TURN cap (@max_runs = 3 there).
  @default_max_runs 12

  # Turns to wait between goal-verification rounds once the goal has already
  # been verified at least once (mirrors GOAL_REVERIFY_AFTER_DEFAULT = 8).
  @default_reverify_after 8

  # Consecutive identical gap fingerprints (across turns) that trip the
  # cross-turn stall auto-pause (mirrors GOAL_CLASSIFIER_STALL_THRESHOLD).
  @default_stall_threshold 2

  @history_max 32

  # ---------------------------------------------------------------------------
  # Config gate
  # ---------------------------------------------------------------------------

  @doc """
  `true` when cross-turn goal orchestration should run for this session.

  Resolution precedence mirrors `GoalVerifier.activated?/1` exactly (so the
  cross-turn tracker auto-activates under the same conditions as the
  single-turn panel — otherwise the auto-pause path in `react_loop.ex` would
  evaluate `paused?/1` against a tracker that was never opted in):

    1. explicit `config :optimal_system_agent, goal_tracker_enabled: true` or
       `false` — returned verbatim (operator override wins).
    2. `:auto` (the default) — ON when the turn is autonomous/long-running
       per the shared `GoalVerifier.autonomous_posture?/1` predicate
       (overdrive/bypass mode, an anchored goal loop, or a long turn), OFF for
       ordinary short interactive turns.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(state) when is_map(state) do
    case Application.get_env(:optimal_system_agent, :goal_tracker_enabled, :auto) do
      true -> true
      false -> false
      _auto -> GoalVerifier.autonomous_posture?(state)
    end
  end

  def enabled?(_), do: false

  @doc """
  `true` when this session is an explicitly-anchored, still-live goal loop —
  a real goal was set via `start/2` (the snapshot carries non-nil goal text)
  and it is still `:active`/`:off_track`.

  Distinguished from a bare, lazily-`ensure/1`'d entry (which `tick_turn/1`
  creates for EVERY session and which has no goal text): only a session
  actually driving a goal counts as a goal loop for smart-activation
  purposes. Used by `GoalVerifier.autonomous_posture?/1`.
  """
  @spec goal_loop?(String.t()) :: boolean()
  def goal_loop?(session_id) when is_binary(session_id) do
    case get(session_id) do
      %Snapshot{goal: goal, status: status}
      when is_binary(goal) and goal != "" and status in [:active, :off_track] ->
        true

      _ ->
        false
    end
  end

  def goal_loop?(_), do: false

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  (Re)anchor a goal for `session_id`: creates a fresh `:active`/`:executing`
  snapshot (clearing any prior stall/pause bookkeeping) and writes `goal`
  into the `ProgressLedger`'s `## Goal` section. Idempotent to call again
  with a new goal text (e.g. `/goal` re-issued) — always resets to `:active`.
  """
  @spec start(String.t(), String.t()) :: Snapshot.t()
  def start(session_id, goal) when is_binary(session_id) and is_binary(goal) do
    snap = %Snapshot{
      session_id: session_id,
      status: :active,
      phase: :executing,
      goal: goal,
      updated_at: DateTime.utc_now()
    }

    put(snap)
    ProgressLedger.set_goal(session_id, goal)
    log(session_id, "[goal-tracker] goal started: #{goal}")
    emit(snap, :started)
    snap
  end

  @doc """
  Get-or-lazily-create the snapshot for `session_id`. Unlike `start/2` this
  never resets an existing goal — it only seeds a fresh `:active`/`:executing`
  entry the first time a session is seen, so callers that only know
  `session_id` (not the goal text) can safely call this every turn.
  """
  @spec ensure(String.t()) :: Snapshot.t()
  def ensure(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil ->
        snap = %Snapshot{session_id: session_id, updated_at: DateTime.utc_now()}
        put(snap)
        snap

      snap ->
        snap
    end
  end

  @doc """
  Call once at the START of every new top-level turn (one user message /
  one call into the loop). Lazily creates the tracker entry (via `ensure/1`)
  and, while the goal is still live (`:active` or `:off_track`), advances
  `turn_count` and `rounds_since_verify` by one. A `:paused`/`:completed`
  goal is left untouched — turn counting for a halted goal is meaningless.
  """
  @spec tick_turn(String.t()) :: Snapshot.t()
  def tick_turn(session_id) when is_binary(session_id) do
    snap = ensure(session_id)

    snap =
      if snap.status in [:active, :off_track] do
        %{
          snap
          | turn_count: snap.turn_count + 1,
            rounds_since_verify: snap.rounds_since_verify + 1,
            updated_at: DateTime.utc_now()
        }
      else
        snap
      end

    put(snap)
    snap
  end

  # ---------------------------------------------------------------------------
  # Cadence gate — "don't re-verify every single turn"
  # ---------------------------------------------------------------------------

  @doc """
  `true` when a goal-verification round is due THIS turn: no tracker entry
  yet (defer entirely to `GoalVerifier`'s own per-turn gating — this module
  never blocks a session it hasn't seen), the goal is still live, the
  lifetime run cap has budget left, and either this would be the very first
  verification round OR at least `reverify_after/0` turns have elapsed since
  the last one.
  """
  @spec reverify_due?(String.t()) :: boolean()
  def reverify_due?(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil ->
        true

      %Snapshot{status: status} when status not in [:active, :off_track] ->
        false

      %Snapshot{verify_run_count: 0} ->
        true

      %Snapshot{verify_run_count: runs, rounds_since_verify: rounds} ->
        runs < max_runs() and rounds >= reverify_after()
    end
  end

  def reverify_due?(_), do: true

  # ---------------------------------------------------------------------------
  # Core transition — call after a GoalVerifier round actually ran
  # ---------------------------------------------------------------------------

  @doc """
  Advance the cross-turn state machine from one `GoalVerifier.Result.t()`
  (a verification round that just ran). Returns the updated `Snapshot.t()`.

  Transitions:

    * `:complete`   -> `:active -> :completed` (terminal; `phase: :idle`).
    * `:off_track`  -> `:active -> :off_track`; queues a re-plan directive on
      the `Steer` queue so the NEXT turn is nudged to reconsider its
      approach rather than "try harder" on a judged-unachievable goal.
    * `:incomplete` -> stall bookkeeping runs on the normalized gap
      fingerprint (mirrors `GoalVerifier`'s own within-turn fingerprint,
      computed independently here so this module has no private coupling):
        - two consecutive rounds (which may be turns apart) with the
          IDENTICAL fingerprint -> `:active -> :paused`,
          `pause_reason: :no_progress`.
        - lifetime run cap exhausted -> `:active -> :paused`,
          `pause_reason: :run_cap`.
        - otherwise stays `:active` (or recovers from `:off_track` back to
          `:active`) and queues a "keep going" reverify nudge once enough
          rounds have elapsed without success (mirrors grok's
          `render_goal_reverify_block`).

  Every transition appends a line to `ProgressLedger`'s `## Log` and emits a
  `:system_event` (`event: :goal_tracker_transition`) for the TUI/telemetry.
  """
  @spec advance(String.t(), GoalVerifier.Result.t()) :: Snapshot.t()
  def advance(session_id, %GoalVerifier.Result{} = result) when is_binary(session_id) do
    snap = ensure(session_id)

    snap = %{
      snap
      | verify_run_count: snap.verify_run_count + 1,
        rounds_since_verify: 0,
        updated_at: DateTime.utc_now()
    }

    snap = apply_verdict(snap, result)
    put(snap)
    snap
  end

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :complete} = result) do
    snap = %{
      snap
      | status: :completed,
        phase: :idle,
        pause_reason: nil,
        last_gap_fingerprint: nil,
        stall_count: 0
    }

    transition(snap, "goal COMPLETED — #{result.reason}")
  end

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :off_track} = result) do
    snap = %{snap | status: :off_track, phase: :planning}
    steer_replan(snap.session_id, result)
    transition(snap, "goal OFF-TRACK — #{result.reason}; re-plan nudge queued")
  end

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :incomplete} = result) do
    fingerprint = gap_fingerprint(result.gaps)
    {stall_count, stalled?} = advance_stall(snap, fingerprint)

    snap = %{snap | last_gap_fingerprint: fingerprint, stall_count: stall_count}

    cond do
      stalled? ->
        snap
        |> Map.merge(%{status: :paused, pause_reason: :no_progress})
        |> transition(
          "goal PAUSED (no_progress) — #{stall_count} consecutive rounds cited the same gap(s): " <>
            Enum.join(result.gaps, "; ")
        )

      snap.verify_run_count >= max_runs() ->
        snap
        |> Map.merge(%{status: :paused, pause_reason: :run_cap})
        |> transition(
          "goal PAUSED (run_cap) — lifetime verification cap (#{max_runs()}) reached, " <>
            "still incomplete: #{result.reason}"
        )

      true ->
        snap = %{snap | status: :active, phase: :executing, pause_reason: nil}
        steer_reverify_nudge(snap, result)
        transition(snap, "goal INCOMPLETE round #{snap.verify_run_count} — #{result.reason}")
    end
  end

  # Fail-closed default for a malformed/unexpected result — treat as
  # incomplete-with-no-gaps rather than silently completing.
  defp apply_verdict(snap, other) do
    apply_verdict(snap, %GoalVerifier.Result{verdict: :incomplete, reason: inspect(other)})
  end

  # `count` tracks consecutive occurrences (in a row, ACROSS TURNS) of the
  # CURRENT gap fingerprint. Trips once `count >= stall_threshold()`, i.e.
  # the default of 2 trips on the SECOND consecutive round citing the
  # identical gap set — mirrors `GoalVerifier.advance_stall/3` and grok's
  # `record_classifier_stall`.
  defp advance_stall(%Snapshot{last_gap_fingerprint: last, stall_count: prev}, fingerprint) do
    cond do
      last != nil and last == fingerprint ->
        count = prev + 1
        {count, count >= stall_threshold()}

      true ->
        {1, 1 >= stall_threshold()}
    end
  end

  defp steer_replan(session_id, result) do
    gaps = gaps_block(result.gaps)

    Steer.queue(
      session_id,
      "[Goal tracker: OFF-TRACK] The independent skeptic panel judged your current approach to " <>
        "this goal NOT achievable as framed (not merely unfinished):\n#{gaps}\n" <>
        "Re-read the goal, reconsider your plan, and take a materially different approach — or " <>
        "explain clearly why the goal cannot be met as stated."
    )
  end

  defp steer_reverify_nudge(snap, result) do
    threshold = reverify_after()

    if snap.verify_run_count >= threshold do
      lead =
        if snap.verify_run_count >= threshold * 3 do
          "STOP DRIFTING — RE-VERIFY NOW."
        else
          "Re-verify before continuing."
        end

      Steer.queue(
        snap.session_id,
        "[Goal tracker] #{lead} You have run #{snap.verify_run_count}/#{max_runs()} goal-" <>
          "verification rounds without the panel agreeing the goal is complete. Name the single " <>
          "concrete gap still blocking it and fix exactly that — do not make cosmetic changes to " <>
          "look busy. Current gap(s):\n#{gaps_block(result.gaps)}"
      )
    end
  end

  defp gaps_block([]), do: "  (no structured findings — treat as a general re-check.)"
  defp gaps_block(gaps), do: Enum.map_join(gaps, "\n", &"  - #{&1}")

  defp transition(snap, message) do
    history = Enum.take([message | snap.history], @history_max)
    snap = %{snap | history: history}

    log(snap.session_id, "[goal-tracker] #{message}")
    emit(snap, :transition, %{message: message})

    Logger.info(
      "[goal-tracker] session=#{snap.session_id} status=#{snap.status} phase=#{snap.phase} " <>
        message
    )

    snap
  end

  # ---------------------------------------------------------------------------
  # Manual controls
  # ---------------------------------------------------------------------------

  @doc "Manually pause the goal (e.g. user-initiated `/goal pause`)."
  @spec pause(String.t(), pause_reason()) :: Snapshot.t()
  def pause(session_id, reason \\ :user) when is_binary(session_id) do
    snap = ensure(session_id)
    snap = %{snap | status: :paused, pause_reason: reason, updated_at: DateTime.utc_now()}
    put(snap)
    transition(snap, "goal PAUSED (#{reason}) — manual")
  end

  @doc """
  Resume a paused/off-track goal back to `:active`/`:executing`, clearing
  stall bookkeeping so the next verification round starts a fresh fingerprint
  comparison (mirrors grok's `reset_classifier_stall`).
  """
  @spec resume(String.t()) :: Snapshot.t()
  def resume(session_id) when is_binary(session_id) do
    snap = ensure(session_id)

    snap = %{
      snap
      | status: :active,
        phase: :executing,
        pause_reason: nil,
        last_gap_fingerprint: nil,
        stall_count: 0,
        rounds_since_verify: 0,
        updated_at: DateTime.utc_now()
    }

    put(snap)
    transition(snap, "goal RESUMED")
  end

  @doc "Forget the tracker entry for `session_id` (test / new-goal cleanup)."
  @spec reset(String.t()) :: :ok
  def reset(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @spec snapshot(String.t()) :: Snapshot.t() | nil
  def snapshot(session_id) when is_binary(session_id), do: get(session_id)

  @spec status(String.t()) :: status() | nil
  def status(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil -> nil
      snap -> snap.status
    end
  end

  @spec phase(String.t()) :: phase() | nil
  def phase(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil -> nil
      snap -> snap.phase
    end
  end

  @spec paused?(String.t()) :: boolean()
  def paused?(session_id), do: status(session_id) == :paused

  @spec completed?(String.t()) :: boolean()
  def completed?(session_id), do: status(session_id) == :completed

  @spec off_track?(String.t()) :: boolean()
  def off_track?(session_id), do: status(session_id) == :off_track

  @doc """
  `true` when the loop should keep autonomously driving this goal: no
  tracker entry (never blocks an untracked session), `:active`, or
  `:off_track` (a redirect, not a hard stop — the re-plan nudge is already
  queued via `Steer`). `false` for `:paused` (stall/run-cap/manual halt —
  requires `resume/1`) and `:completed` (goal achieved).
  """
  @spec continue?(String.t()) :: boolean()
  def continue?(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil -> true
      %Snapshot{status: status} -> status in [:active, :off_track]
    end
  end

  # ---------------------------------------------------------------------------
  # Gap fingerprint (independent re-implementation of GoalVerifier's private
  # `fingerprint/1` — same identifier-extraction algorithm, exposed publicly
  # so this module has no coupling to GoalVerifier internals and callers can
  # inspect/test fingerprints directly).
  #
  # Hashing raw normalized `reason` strings (the old algorithm) never
  # actually trips the stall detector: two consecutive rounds citing the
  # exact same underlying gap essentially never produce byte-identical LLM
  # prose, so the fingerprint changes every round and stall/no-progress
  # auto-pause was effectively dead (finding #10 / D3). Fingerprint on a
  # STABLE signal instead — the sorted, deduplicated set of concrete gap
  # identifiers (file paths, module names, snake_case symbols) mentioned in
  # each gap, falling back to a normalized significant-word bag when no
  # identifier is present.
  # ---------------------------------------------------------------------------

  @spec gap_fingerprint([String.t()]) :: integer()
  def gap_fingerprint(gaps) when is_list(gaps) do
    gaps
    |> Enum.flat_map(&gap_identifiers/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> :erlang.phash2()
  end

  @path_re ~r/\b[\w\-]+(?:\/[\w\-]+)+\.\w{1,6}\b/
  @dotted_module_re ~r/\b[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)+\b/
  @snake_symbol_re ~r/\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/

  defp gap_identifiers(gap) when is_binary(gap) do
    identifiers =
      (Regex.scan(@path_re, gap) ++
         Regex.scan(@dotted_module_re, gap) ++
         Regex.scan(@snake_symbol_re, gap))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    cond do
      identifiers != [] ->
        identifiers

      significant_words(gap) != [] ->
        significant_words(gap)

      true ->
        # Short/terse gap with no extractable identifier AND no word long
        # enough to survive the stopword/length filter (e.g. "gap A" vs
        # "gap B"). Falling through to an empty list here would collapse
        # every such gap to the SAME fingerprint, hiding genuinely different
        # gaps behind a false stall. Last-resort: the normalized whole
        # string, so distinct short gaps still compare distinct.
        [normalize_gap(gap)]
    end
  end

  defp gap_identifiers(_), do: []

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

  defp normalize_gap(gap) when is_binary(gap), do: String.downcase(String.trim(gap))
  defp normalize_gap(_), do: ""

  # ---------------------------------------------------------------------------
  # Env-overridable knobs
  # ---------------------------------------------------------------------------

  @spec max_runs() :: pos_integer()
  def max_runs do
    Application.get_env(:optimal_system_agent, :goal_tracker_max_runs, @default_max_runs)
  end

  @spec reverify_after() :: pos_integer()
  def reverify_after do
    Application.get_env(
      :optimal_system_agent,
      :goal_tracker_reverify_after,
      @default_reverify_after
    )
  end

  @spec stall_threshold() :: pos_integer()
  def stall_threshold do
    Application.get_env(
      :optimal_system_agent,
      :goal_tracker_stall_threshold,
      @default_stall_threshold
    )
  end

  # ---------------------------------------------------------------------------
  # ETS storage (lazily-created public table, mirrors `Agent.PermissionMode`)
  # ---------------------------------------------------------------------------

  defp get(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, snap}] -> snap
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put(%Snapshot{session_id: session_id} = snap) do
    ensure_table()
    :ets.insert(@table, {session_id, snap})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Best-effort durable log line — a ledger write must never break a
  # transition.
  defp log(session_id, message) do
    ProgressLedger.append_entry(session_id, message)
    :ok
  rescue
    _ -> :ok
  end

  defp emit(snap, event, extra \\ %{}) do
    Bus.emit(
      :system_event,
      Map.merge(extra, %{
        event: :goal_tracker_transition,
        action: event,
        session_id: snap.session_id,
        status: snap.status,
        phase: snap.phase,
        pause_reason: snap.pause_reason,
        turn_count: snap.turn_count,
        verify_run_count: snap.verify_run_count
      })
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
