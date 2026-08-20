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
    * reuses `Agent.ProgressLedger` as the durable PROSE goal store —
      `start/2` writes the goal into the ledger's `## Goal` section, and
      every status transition is appended to the ledger's `## Log`.

  ## Durability (why the ETS table is not the whole store)

  The ETS table is a per-BEAM cache, not the store. `Agent.ProgressLedger`
  states the operative fact: **every `osa` invocation is its own BEAM**. A
  table-only state machine therefore dies at each CLI invocation boundary,
  and both `paused?/1` and `continue?/1` fall through their `nil ->` branch —
  so a goal auto-paused for `:no_progress` or `:run_cap` would resume
  autonomously with a fresh run budget on the very next invocation. The
  circuit breaker would reset every time it was needed.

  So every mutation is mirrored to a durable JSON sidecar next to the
  session's ledger and its full-state JSON:

      ~/.osa/sessions/<safe_id>.json          # full message state (resume)
      ~/.osa/sessions/<safe_id>.progress.md   # progress ledger (prose)
      ~/.osa/sessions/<safe_id>.goal.json     # THIS module's state machine

  written through `System.AtomicFile` (temp + fsync + rename), the same
  crash-safe primitive `Agent.Loop.Checkpoint` and `ProgressLedger` use. An
  ETS miss rehydrates from that sidecar before answering `nil`, so everything
  that gates continuation — goal text, `goal_id`, `verify_run_count`, the
  stall streak, `pause_reason`, and the transition history — round-trips
  across invocations. `reset/1` clears both halves.

  ## Goal identity

  A goal carries a `goal_id` minted by `start/2` and stable across
  pause -> resume -> complete. `ProgressLedger.set_goal/3` records it as a
  `[goal-anchor:<id>]` marker in the `## Log`, and every transition line this
  module writes is prefixed `[goal:<id>]`, so a re-issued `/goal` can no
  longer render its new `## Goal` head over log lines that belong entirely to
  the previous goal (`ProgressLedger.summarize/1` cuts at the last anchor).

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
  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.System.AtomicFile

  @table :osa_goal_tracker

  @type status :: :active | :paused | :completed | :off_track | :blocked | :abandoned
  @type phase :: :idle | :planning | :executing
  @type pause_reason ::
          :no_progress | :run_cap | :usage_limits | :off_track | :user | :blocked | :abandoned | nil

  defmodule Snapshot do
    @moduledoc "Persisted per-session goal-tracker state."
    @type t :: %__MODULE__{
            session_id: String.t(),
            status: OptimalSystemAgent.Agent.Loop.GoalTracker.status(),
            phase: OptimalSystemAgent.Agent.Loop.GoalTracker.phase(),
            goal_id: String.t() | nil,
            goal: String.t() | nil,
            turn_count: non_neg_integer(),
            rounds_since_verify: non_neg_integer(),
            verify_run_count: non_neg_integer(),
            last_gap_fingerprint: integer() | nil,
            last_work_marker: non_neg_integer() | nil,
            token_budget: pos_integer() | nil,
            tokens_at_start: non_neg_integer() | nil,
            tokens_used: non_neg_integer(),
            started_at: DateTime.t() | nil,
            stall_count: non_neg_integer(),
            pause_reason: OptimalSystemAgent.Agent.Loop.GoalTracker.pause_reason(),
            blocked_claims: non_neg_integer(),
            blocked_claim_turn: non_neg_integer() | nil,
            abandoned_count: non_neg_integer(),
            history: [String.t()],
            updated_at: DateTime.t() | nil
          }
    defstruct session_id: nil,
              status: :active,
              phase: :executing,
              goal_id: nil,
              goal: nil,
              turn_count: 0,
              rounds_since_verify: 0,
              verify_run_count: 0,
              last_gap_fingerprint: nil,
              last_work_marker: nil,
              # Opt-in, nullable — mirrors Codex's `token_budget`, whose own tool
              # doc says "Omit unless explicitly requested". A goal with no
              # budget is unbounded; the ceiling is a thing the operator asks
              # for, not a default that ambushes a long run.
              token_budget: nil,
              tokens_at_start: nil,
              tokens_used: 0,
              started_at: nil,
              stall_count: 0,
              pause_reason: nil,
              blocked_claims: 0,
              blocked_claim_turn: nil,
              abandoned_count: 0,
              history: [],
              updated_at: nil
  end

  # ── Config (env-overridable, mirrors grok's GROK_GOAL_CLASSIFIER_MAX /
  #    GROK_GOAL_REVERIFY_AFTER / GOAL_CLASSIFIER_STALL_THRESHOLD) ──

  # Lifetime run cap ACROSS THE WHOLE GOAL (all turns), distinct from
  # GoalVerifier's own smaller PER-TURN cap (@max_runs = 3 there).
  # Lifetime verification-round cap. OFF by default.
  #
  # Counting verification rounds is the wrong shape for bounding a goal, and
  # Codex does not do it: its `thread_goals` carries an OBJECTIVE and an
  # optional `token_budget` ("Omit unless explicitly requested"), and its goal
  # tool reports "status, budgets, token and elapsed-time usage, remaining token
  # budget". Cost and elapsed time are the real resources; a round count is a
  # proxy that punishes thoroughness — verifying more often made a goal MORE
  # likely to be killed, which is backwards.
  #
  # A goal now ends for a reason, not for a count: achieved, off-track,
  # genuinely stalled (unchanged gaps AND no work landing), out of budget
  # (`max_budget_usd`, opt-in), or stopped by the operator. Set
  # `:goal_tracker_max_runs` to re-impose a ceiling for a bounded run.
  @default_max_runs :infinity

  # Turns to wait between goal-verification rounds once the goal has already
  # been verified at least once (mirrors GOAL_REVERIFY_AFTER_DEFAULT = 8).
  @default_reverify_after 8

  # Consecutive identical gap fingerprints (across turns) that trip the
  # cross-turn stall auto-pause (mirrors GOAL_CLASSIFIER_STALL_THRESHOLD).
  # Consecutive rounds with UNCHANGED gaps AND no work landed before pausing.
  #
  # Two is deliberate and unchanged: what was wrong was never the count, it was
  # that the count advanced on gaps alone. A goal spans many plans, so while the
  # agent works through plan 1 of 3 the goal's gaps ("plans 2 and 3 outstanding")
  # are identical every round — because they genuinely are. Two rounds of that
  # paused the goal with a plan just completed 6/6.
  #
  # With `work_landed?/2` vetoing those rounds, two consecutive rounds where
  # NOTHING moved is a fair definition of stuck.
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

  ## Options

    * `:acceptance_criteria` — what "done" means for this goal, in checkable
      terms. Forwarded through `ProgressLedger.set_goal/3` to
      `Agent.TaskBrief.capture/3`, which freezes it and re-injects it into the
      `role: "system"` block on every subsequent turn.

      Supplying it AT ANCHOR TIME is the only way to get real criteria into the
      brief: the brief is immutable and captured by the first goal-set, so a
      later attempt to add criteria is silently ignored. Absent this option the
      brief falls back to storing the goal text as its own acceptance criteria.

    * `:constraints` — hard constraints, same freezing semantics.
  """
  @spec start(String.t(), String.t(), keyword()) :: Snapshot.t()
  def start(session_id, goal, opts \\ [])

  def start(session_id, goal, opts)
      when is_binary(session_id) and is_binary(goal) and is_list(opts) do
    # A fresh identity per anchoring. It is what makes the ledger's `## Log`
    # attributable: without it, a re-issued `/goal` overwrote the `## Goal`
    # head in place while the previous goal's log lines stayed put, and
    # `summarize/1` then rendered the NEW goal over the OLD goal's history.
    goal_id = new_goal_id()

    snap = %Snapshot{
      session_id: session_id,
      status: :active,
      phase: :executing,
      goal_id: goal_id,
      goal: goal,
      # Both nil unless the caller asked for a budget. An unbudgeted goal runs
      # until it is achieved, goes off-track, genuinely stalls, or the operator
      # stops it - never until a counter runs out.
      token_budget: normalize_budget(Keyword.get(opts, :token_budget)),
      tokens_at_start: Keyword.get(opts, :tokens_used),
      tokens_used: 0,
      started_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    put(snap)

    ProgressLedger.set_goal(
      session_id,
      goal,
      Keyword.merge(Keyword.take(opts, [:acceptance_criteria, :constraints]), goal_id: goal_id)
    )

    log(session_id, tag(snap, "[goal-tracker] goal started: #{goal}"))
    emit(snap, :started)
    snap
  end

  @doc """
  The MODEL-facing anchor. Unlike `start/3` — which is the USER's `/goal`, and
  may re-anchor at will — this refuses while a goal is still unfinished.

  Ported from Codex's `create_goal`, which fails with "cannot create a new goal
  because this thread has an unfinished goal; complete the existing goal first"
  and whose `update_goal` hardcodes `objective: None`. Between them the model
  can author its objective exactly once and can never edit it afterwards.

  That refusal IS the honesty mechanism. A self-authored definition of done is
  only dangerous if it can be re-authored: the failure mode is not writing an
  easy goal at t=0 (the panel still judges it against the founding request), it
  is quietly swapping in an easier one at t=n once the hard one looks unwinnable
  — which `start/3` would happily do, resetting `verify_run_count`, `stall_count`
  and `turn_count` and handing the run a fresh budget in the bargain.

  Returns `{:error, {:goal_active, snap}}` while a goal is `:active`/`:off_track`.
  A `:paused`, `:blocked`, `:abandoned` or `:completed` goal may be superseded.

  ## The budget does not reset across a model-reachable terminal

  Two of the terminals a goal can reach are ones the MODEL puts it in:
  `:blocked` (`claim_blocked/1`) and `:abandoned` (`abandon/1`). Superseding
  either one carries `turn_count`, `verify_run_count` and `abandoned_count`
  forward into the successor.

  That carry is what keeps the exits from being the loophole the freeze exists
  to stop. The danger in re-anchoring was never the new objective by itself — it
  was that a fresh snapshot handed the run a fresh lifetime budget and a clean
  stall slate, so a model that could not finish a hard goal had an incentive to
  end it and start again. Carrying the counters removes the incentive: ending a
  goal redirects the run, it cannot refill it. `:completed` (earned through the
  panel) and `:paused` (the user's or the system's call, and it halts the loop
  anyway) start clean, as does the user's own `start/3`.
  """
  @spec anchor_new(String.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, {:goal_active, Snapshot.t()}}
  def anchor_new(session_id, goal, opts \\ [])

  def anchor_new(session_id, goal, opts)
      when is_binary(session_id) and is_binary(goal) and is_list(opts) do
    case get(session_id) do
      %Snapshot{status: status, goal: existing} = snap
      when status in [:active, :off_track] and is_binary(existing) and existing != "" ->
        {:error, {:goal_active, snap}}

      %Snapshot{status: status} = prior when status in [:blocked, :abandoned] ->
        {:ok, carry_budget(start(session_id, goal, opts), prior)}

      _ ->
        {:ok, start(session_id, goal, opts)}
    end
  end

  defp carry_budget(%Snapshot{} = snap, %Snapshot{} = prior) do
    snap = %{
      snap
      | turn_count: prior.turn_count,
        verify_run_count: prior.verify_run_count,
        abandoned_count: prior.abandoned_count
    }

    put(snap)

    log(
      session_id_of(snap),
      tag(
        snap,
        "[goal-tracker] successor goal inherits the spent budget: " <>
          "#{snap.turn_count} turn(s), #{snap.verify_run_count}/#{max_runs()} " <>
          "verification round(s)"
      )
    )

    snap
  end

  defp session_id_of(%Snapshot{session_id: sid}), do: sid

  @doc """
  Record the model's decision to ABANDON the live goal: this work is no longer
  the objective, and the objective will not be met.

  ## Why this exists, given that the freeze is the point

  Codex's `create_goal` refuses outright while a goal is unfinished, and that
  bluntness is deliberate — from inside a tracker, abandoning a goal and
  swapping in an easier one are the same API call with different intent, so it
  forbids both. The cost is that an agent whose work legitimately changed
  direction had NO model-reachable exit: `claim_complete/1` cannot reach
  `:completed` by design, `claim_blocked/1` needs three consecutive goal turns
  (and `turn_count` only advances at the start of a new TOP-LEVEL turn, so
  inside one unattended autonomous turn the streak is pinned at 1), and
  `pause/2` / `resume/1` / `reset/1` belong to the user. Under `overdrive` with
  nobody at the keyboard, that is a deadlock: the real work cannot be anchored
  and no human is coming to type `/goal clear`.

  The two intents stay indistinguishable from in here. What separates them is
  not detection but PRICE, and this sets one that only the honest case will pay:

    * it is terminal for that goal — `continue?/1` and `goal_loop?/1` both go
      false, so the run stops driving an objective it just conceded;
    * it is permanently recorded, against the objective it gave up on, in the
      snapshot history and in the `ProgressLedger` `## Log` under the goal's own
      id. An abandoned goal that left no trace would be indistinguishable from
      one that was quietly swapped, which is the thing worth being able to audit
      afterwards;
    * and the successor inherits the spent budget (see `anchor_new/3`). Swapping
      for an easier objective bought a fresh run cap and a clean stall slate;
      after this it buys nothing at all.

  Returns `{:ok, snap}`, or `{:error, :not_live}` when there is no live goal.
  """
  @spec abandon(String.t()) :: {:ok, Snapshot.t()} | {:error, :not_live}
  def abandon(session_id) when is_binary(session_id) do
    case get(session_id) do
      %Snapshot{status: status, goal: goal} = snap when status in [:active, :off_track] ->
        snap = %{
          snap
          | status: :abandoned,
            phase: :idle,
            pause_reason: :abandoned,
            abandoned_count: snap.abandoned_count + 1,
            updated_at: DateTime.utc_now()
        }

        snap = transition(snap, "goal ABANDONED — #{goal}")
        put(snap)
        emit(snap, :abandoned)
        {:ok, snap}

      _ ->
        {:error, :not_live}
    end
  end

  @doc """
  Record the model's claim that the goal is met.

  This deliberately does NOT set `:completed`. Only `advance/2` with a
  `:complete` verdict from the skeptic panel can do that, and this function
  cannot reach it — all it does is make the next panel round DUE, by zeroing the
  distance to the reverify cadence.

  This is grok-build's rule, where `update_goal(completed: true)` completes the
  goal only when the classifier is disabled entirely
  (`UpdateGoalAck::CompletedWithoutClassifier`). Codex has no equivalent: there,
  `update_goal(status: "complete")` writes `complete` straight to the database
  and the only thing standing between a self-authored goal and a self-declared
  success is the wording of the continuation prompt.

  Returns `{:ok, snap}`, or `{:error, :not_live}` when there is no live goal.
  """
  @spec claim_complete(String.t()) :: {:ok, Snapshot.t()} | {:error, :not_live}
  def claim_complete(session_id) when is_binary(session_id) do
    case get(session_id) do
      %Snapshot{status: status} = snap when status in [:active, :off_track] ->
        snap = %{
          snap
          | rounds_since_verify: max(snap.rounds_since_verify, reverify_after()),
            updated_at: DateTime.utc_now()
        }

        put(snap)
        log(session_id, tag(snap, "[goal-tracker] completion claimed; verification forced"))
        {:ok, snap}

      _ ->
        {:error, :not_live}
    end
  end

  @doc """
  Record the model's claim that it is blocked.

  The claim only takes effect on the THIRD consecutive goal turn that carries
  it. Both reference harnesses require exactly three, but only grok-build
  enforces it in the harness rather than in prose — Codex states the rule in the
  `update_goal` tool description and the continuation prompt and then trusts the
  model to count, which a model that wants to stop has every reason not to do.

  Consecutiveness is measured in goal TURNS, not calls: repeated claims inside
  one turn cannot ratchet the streak, and a turn that passes without a claim
  resets it to zero.

  Returns `{:blocked, snap}` once the threshold is met, `{:pending, streak, snap}`
  below it, or `{:error, :not_live}`.
  """
  @spec claim_blocked(String.t()) ::
          {:blocked, Snapshot.t()} | {:pending, pos_integer(), Snapshot.t()} | {:error, :not_live}
  def claim_blocked(session_id) when is_binary(session_id) do
    case get(session_id) do
      %Snapshot{status: status} = snap when status in [:active, :off_track] ->
        streak = blocked_streak(snap)

        snap = %{
          snap
          | blocked_claims: streak,
            blocked_claim_turn: snap.turn_count,
            updated_at: DateTime.utc_now()
        }

        if streak >= blocked_threshold() do
          snap = %{snap | status: :blocked, phase: :idle, pause_reason: :blocked}
          put(snap)

          log(
            session_id,
            tag(snap, "[goal-tracker] goal blocked after #{streak} consecutive claims")
          )

          emit(snap, :blocked)
          {:blocked, snap}
        else
          put(snap)

          log(
            session_id,
            tag(snap, "[goal-tracker] blocked claim #{streak}/#{blocked_threshold()} recorded")
          )

          {:pending, streak, snap}
        end

      _ ->
        {:error, :not_live}
    end
  end

  # A claim already made this turn is idempotent, not cumulative. A claim on the
  # turn immediately after the last one extends the streak; anything else starts
  # a new one.
  defp blocked_streak(%Snapshot{blocked_claim_turn: nil}), do: 1

  defp blocked_streak(%Snapshot{blocked_claim_turn: last, turn_count: now, blocked_claims: n}) do
    cond do
      last == now -> max(n, 1)
      last == now - 1 -> n + 1
      true -> 1
    end
  end

  @doc "Consecutive blocked claims required before a goal actually goes `:blocked`."
  @spec blocked_threshold() :: pos_integer()
  def blocked_threshold do
    case Application.get_env(:optimal_system_agent, :goal_blocked_threshold, 3) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 3
    end
  end

  defp new_goal_id do
    OptimalSystemAgent.Utils.ID.generate()
  rescue
    _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Prefix a durable log line with the goal it belongs to. A snapshot with no
  # anchored goal (a bare `ensure/1` row) is left untagged rather than given a
  # fake identity.
  defp tag(%Snapshot{goal_id: id}, message) when is_binary(id) and id != "",
    do: "[goal:#{id}] " <> message

  defp tag(_snap, message), do: message

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
  def advance(session_id, result), do: advance(session_id, result, nil)

  @doc """
  As `advance/2`, with a monotonic `work_marker` describing how much work has
  landed for this session (the session-wide tool-call count).

  Stall detection needs it. Judging progress by the gap list alone cannot
  distinguish "nothing happened" from "real work happened but the goal is big
  enough that the same gaps are still outstanding" - and the second is the
  normal case for any multi-plan goal. When the marker has moved, work landed,
  and the round is not a stall however familiar the gaps look.
  """
  @spec advance(String.t(), GoalVerifier.Result.t(), non_neg_integer() | nil) :: Snapshot.t()
  def advance(session_id, %GoalVerifier.Result{} = result, work_marker)
      when is_binary(session_id) do
    snap = ensure(session_id)

    snap = %{
      snap
      | verify_run_count: snap.verify_run_count + 1,
        rounds_since_verify: 0,
        updated_at: DateTime.utc_now()
    }

    snap = apply_verdict(snap, result, work_marker)
    put(snap)
    snap
  end

  defp apply_verdict(snap, result, work_marker \\ nil)

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :complete} = result, _work) do
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

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :off_track} = result, _work) do
    snap = %{snap | status: :off_track, phase: :planning}
    steer_replan(snap.session_id, result)
    transition(snap, "goal OFF-TRACK — #{result.reason}; re-plan nudge queued")
  end

  defp apply_verdict(snap, %GoalVerifier.Result{verdict: :incomplete} = result, work_marker) do
    fingerprint = gap_fingerprint(result.gaps)
    {stall_count, stalled?} = advance_stall(snap, fingerprint, work_marker)

    snap = %{
      snap
      | last_gap_fingerprint: fingerprint,
        last_work_marker: work_marker || snap.last_work_marker,
        stall_count: stall_count
    }

    cond do
      stalled? ->
        snap
        |> Map.merge(%{status: :paused, pause_reason: :no_progress})
        |> transition(
          "goal PAUSED (no_progress) — #{stall_count} consecutive rounds cited the same gap(s): " <>
            Enum.join(result.gaps, "; ")
        )

      run_cap_reached?(snap.verify_run_count) ->
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
  defp apply_verdict(snap, other, work_marker) do
    apply_verdict(snap, %GoalVerifier.Result{verdict: :incomplete, reason: inspect(other)}, work_marker)
  end

  # `count` tracks consecutive occurrences (in a row, ACROSS TURNS) of the
  # CURRENT gap fingerprint. Trips once `count >= stall_threshold()`, i.e.
  # the default of 2 trips on the SECOND consecutive round citing the
  # identical gap set — mirrors `GoalVerifier.advance_stall/3` and grok's
  # `record_classifier_stall`.
  # A round only counts toward a stall when the gaps are unchanged AND no work
  # landed since the last verification. Either one moving is progress.
  defp advance_stall(%Snapshot{} = snap, fingerprint, work_marker) do
    same_gaps? = snap.last_gap_fingerprint != nil and snap.last_gap_fingerprint == fingerprint
    work_landed? = work_landed?(snap.last_work_marker, work_marker)

    cond do
      same_gaps? and not work_landed? ->
        count = snap.stall_count + 1
        {count, count >= stall_threshold()}

      # Work landed, or the gaps moved. Either way this round is progress, so
      # the streak restarts at 1 — the same reset the gap-only rule used, so
      # "two rounds where nothing moved" still means two, not three.
      true ->
        {1, 1 >= stall_threshold()}
    end
  end

  # With NO work information, fall back to the gap-only rule.
  #
  # The first attempt treated an unknown marker as "work landed", reasoning that
  # absence of evidence should not read as evidence of a stall. In effect that
  # disabled stall detection outright for every `advance/2` caller — a goal
  # spinning on the same blocker forever would never be caught. The safety net
  # has to survive callers that cannot report progress.
  #
  # So: a marker is only allowed to VETO a stall, never to cause one. When one
  # is present and has moved, work landed. When it is absent we know nothing
  # extra, and the gap fingerprint is the best signal available.
  defp work_landed?(nil, _current), do: false
  defp work_landed?(_previous, nil), do: false
  defp work_landed?(previous, current), do: current > previous

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

    log(snap.session_id, tag(snap, "[goal-tracker] #{message}"))
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
        # "If the user resumes a goal that was previously marked blocked, treat
        # the resumed run as a fresh blocked audit" — Codex's update_goal spec,
        # and grok's behaviour. Carrying the streak across a resume would let the
        # goal re-block on the first claim after the user asked for more work.
        blocked_claims: 0,
        blocked_claim_turn: nil,
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
    # The sidecar is the store; forgetting only the cache would resurrect the
    # row on the next read.
    _ = File.rm(store_path(session_id))
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

  @doc """
  Stable identity of the goal currently anchored for `session_id`, or `nil`
  when no goal was ever anchored via `start/2`. Survives pause -> resume ->
  complete and every BEAM boundary; changes only when `start/2` anchors a NEW
  goal.
  """
  @spec goal_id(String.t()) :: String.t() | nil
  def goal_id(session_id) when is_binary(session_id) do
    case get(session_id) do
      nil -> nil
      snap -> snap.goal_id
    end
  end

  def goal_id(_), do: nil

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

  @spec blocked?(String.t()) :: boolean()
  def blocked?(session_id), do: status(session_id) == :blocked

  @spec abandoned?(String.t()) :: boolean()
  def abandoned?(session_id), do: status(session_id) == :abandoned

  @doc """
  `true` when the loop should keep autonomously driving this goal: no
  tracker entry (never blocks an untracked session), `:active`, or
  `:off_track` (a redirect, not a hard stop — the re-plan nudge is already
  queued via `Steer`). `false` for `:paused` (stall/run-cap/manual halt —
  requires `resume/1`), `:completed` (goal achieved), `:blocked` (an impasse
  the model declared and the harness counted) and `:abandoned` (the model
  conceded the objective — see `abandon/1`).

  Deliberately a whitelist. A new status must opt IN to driving the loop; the
  failure mode of a blacklist here is a terminal state that silently keeps
  spending an unattended run.
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

  @doc "Human-readable verification cap: a number, or \"unlimited\"."
  @spec max_runs_label() :: String.t()
  def max_runs_label do
    case max_runs() do
      n when is_integer(n) and n > 0 -> to_string(n)
      _ -> "unlimited"
    end
  end

  @doc false
  @spec runs_remaining?(non_neg_integer()) :: boolean()
  def runs_remaining?(runs), do: not run_cap_reached?(runs)

  # A budget must be a positive integer or absent. A zero or negative value is
  # discarded rather than obeyed: honouring 0 would end the goal before its
  # first turn, which is never what anyone meant by "set a budget".
  defp normalize_budget(n) when is_integer(n) and n > 0, do: n
  defp normalize_budget(_), do: nil

  @doc """
  Record cumulative token usage for the session and pause the goal when it has
  consumed its budget.

  Cost and elapsed time are the real resources a long goal spends, so they are
  what bounds it — mirroring Codex, whose goal tool reports "status, budgets,
  token and elapsed-time usage, remaining token budget" and pauses on
  `usage >= token_budget`. An unbudgeted goal is never paused by this.
  """
  @spec note_usage(String.t(), non_neg_integer()) :: Snapshot.t()
  def note_usage(session_id, cumulative_tokens)
      when is_binary(session_id) and is_integer(cumulative_tokens) do
    snap = ensure(session_id)
    baseline = snap.tokens_at_start || cumulative_tokens
    used = max(cumulative_tokens - baseline, 0)

    snap = %{
      snap
      | tokens_at_start: baseline,
        tokens_used: used,
        updated_at: DateTime.utc_now()
    }

    snap =
      if snap.status == :active and budget_exhausted?(snap) do
        snap
        |> Map.merge(%{status: :paused, pause_reason: :usage_limits})
        |> transition(
          "goal PAUSED (usage_limits) — spent #{used} of #{snap.token_budget} token budget"
        )
      else
        snap
      end

    put(snap)
    snap
  end

  @doc "Whether a budgeted goal has spent it. Always false with no budget."
  @spec budget_exhausted?(Snapshot.t()) :: boolean()
  def budget_exhausted?(%Snapshot{token_budget: nil}), do: false

  def budget_exhausted?(%Snapshot{token_budget: budget, tokens_used: used})
      when is_integer(budget) and budget > 0,
      do: used >= budget

  def budget_exhausted?(_), do: false

  @doc """
  Tokens left on a budgeted goal, or `:unlimited`.

  Reported rather than merely enforced: an operator who set a budget should be
  able to see it draining, not discover it at the moment the goal stops.
  """
  @spec budget_remaining(Snapshot.t()) :: non_neg_integer() | :unlimited
  def budget_remaining(%Snapshot{token_budget: nil}), do: :unlimited

  def budget_remaining(%Snapshot{token_budget: budget, tokens_used: used}),
    do: max(budget - used, 0)

  @doc "Wall-clock seconds since the goal was anchored, or nil."
  @spec elapsed_seconds(Snapshot.t()) :: non_neg_integer() | nil
  def elapsed_seconds(%Snapshot{started_at: nil}), do: nil

  def elapsed_seconds(%Snapshot{started_at: started}),
    do: max(DateTime.diff(DateTime.utc_now(), started, :second), 0)

  @doc false
  @spec run_cap_reached?(non_neg_integer()) :: boolean()
  def run_cap_reached?(runs) do
    case max_runs() do
      n when is_integer(n) and n > 0 -> runs >= n
      _ -> false
    end
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
  # Storage — durable JSON sidecar (the store) fronted by ETS (a cache).
  #
  # The ETS table alone cannot hold this state: every `osa` invocation is its
  # own BEAM (see `Agent.ProgressLedger`), so a table-only breaker resets at
  # every invocation boundary and an auto-paused goal resumes itself with a
  # fresh run budget. Reads fall back to the sidecar before answering `nil`;
  # writes go to both.
  # ---------------------------------------------------------------------------

  @doc """
  Absolute path to the session's durable goal-tracker sidecar.

  Sits beside `ProgressLedger.path/1` and the session's full-state JSON, using
  the same safe-id scheme.
  """
  @spec store_path(String.t()) :: String.t()
  def store_path(session_id) when is_binary(session_id) do
    Path.join([ConfigFile.config_dir(), "sessions", "#{safe_id(session_id)}.goal.json"])
  end

  defp safe_id(session_id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")

  defp get(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, snap}] -> snap
      _ -> rehydrate(session_id)
    end
  rescue
    ArgumentError -> nil
  end

  # ETS miss: the table may simply be younger than the goal (new BEAM, table
  # re-created, session teardown of a DIFFERENT session). Read the sidecar and
  # re-seed the cache so the rest of the turn is cheap.
  defp rehydrate(session_id) do
    case load_from_disk(session_id) do
      %Snapshot{} = snap ->
        cache(snap)
        snap

      _ ->
        nil
    end
  end

  defp put(%Snapshot{} = snap) do
    cache(snap)
    persist(snap)
    :ok
  end

  defp cache(%Snapshot{session_id: session_id} = snap) do
    ensure_table()
    :ets.insert(@table, {session_id, snap})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Durable half. Best-effort in the same sense every other write in this
  # module is: a failed sidecar write is logged and never breaks a transition,
  # but it is NOT silent — losing this file is what un-trips the breaker.
  defp persist(%Snapshot{session_id: session_id} = snap) do
    case AtomicFile.write(store_path(session_id), Jason.encode!(encode(snap))) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[goal-tracker] could not persist goal state for #{session_id} " <>
            "(#{inspect(reason)}) — the pause/run-cap breaker will not survive this " <>
            "invocation"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("[goal-tracker] persist raised: #{Exception.message(e)}")
      :ok
  end

  defp load_from_disk(session_id) do
    with {:ok, json} <- File.read(store_path(session_id)),
         {:ok, %{} = map} <- Jason.decode(json) do
      decode(session_id, map)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @statuses [:active, :paused, :completed, :off_track, :blocked, :abandoned]
  @phases [:idle, :planning, :executing]
  @pause_reasons [:no_progress, :run_cap, :off_track, :user, :blocked, :abandoned]

  defp encode(%Snapshot{} = snap) do
    %{
      "session_id" => snap.session_id,
      "status" => to_string(snap.status),
      "phase" => to_string(snap.phase),
      "goal_id" => snap.goal_id,
      "goal" => snap.goal,
      "turn_count" => snap.turn_count,
      "rounds_since_verify" => snap.rounds_since_verify,
      "verify_run_count" => snap.verify_run_count,
      "last_gap_fingerprint" => snap.last_gap_fingerprint,
      "stall_count" => snap.stall_count,
      "pause_reason" => snap.pause_reason && to_string(snap.pause_reason),
      "blocked_claims" => snap.blocked_claims,
      "blocked_claim_turn" => snap.blocked_claim_turn,
      "abandoned_count" => snap.abandoned_count,
      "history" => snap.history,
      "updated_at" => snap.updated_at && DateTime.to_iso8601(snap.updated_at)
    }
  end

  # Fail-CLOSED decode: an unrecognized status decodes to `:paused`, never to
  # `:active`. A corrupted sidecar must not be the thing that hands an
  # autonomous run a fresh budget — the whole point of persisting it.
  defp decode(session_id, map) do
    %Snapshot{
      session_id: Map.get(map, "session_id") || session_id,
      status: known_atom(Map.get(map, "status"), @statuses, :paused),
      phase: known_atom(Map.get(map, "phase"), @phases, :executing),
      goal_id: string_or_nil(Map.get(map, "goal_id")),
      goal: string_or_nil(Map.get(map, "goal")),
      turn_count: non_neg_int(Map.get(map, "turn_count")),
      rounds_since_verify: non_neg_int(Map.get(map, "rounds_since_verify")),
      verify_run_count: non_neg_int(Map.get(map, "verify_run_count")),
      last_gap_fingerprint: int_or_nil(Map.get(map, "last_gap_fingerprint")),
      stall_count: non_neg_int(Map.get(map, "stall_count")),
      pause_reason: known_atom(Map.get(map, "pause_reason"), @pause_reasons, nil),
      blocked_claims: non_neg_int(Map.get(map, "blocked_claims")),
      blocked_claim_turn: int_or_nil(Map.get(map, "blocked_claim_turn")),
      abandoned_count: non_neg_int(Map.get(map, "abandoned_count")),
      history: string_list(Map.get(map, "history")),
      updated_at: decode_datetime(Map.get(map, "updated_at"))
    }
  end

  defp known_atom(value, allowed, fallback) when is_binary(value) do
    Enum.find(allowed, fallback, fn a -> Atom.to_string(a) == value end)
  end

  defp known_atom(_value, _allowed, fallback), do: fallback

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp non_neg_int(v) when is_integer(v) and v >= 0, do: v
  defp non_neg_int(_), do: 0

  defp int_or_nil(v) when is_integer(v), do: v
  defp int_or_nil(_), do: nil

  defp string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp string_list(_), do: []

  defp decode_datetime(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp decode_datetime(_), do: nil

  @doc """
  Create the cross-turn goal table up front, owned by the long-lived caller.

  Called from `Application.start/2` (Phase 2) for the same reason as
  `Infra.BoundedTable.init_tables/0` and `Agent.RunStore.init_store/0`: a
  lazily created named table is owned by whatever process happened to insert
  first, and here that is usually a TRANSIENT one (a ReAct loop task, a
  subagent). When that process exits the table vanishes with it.

  Since the state machine is now stored in a durable sidecar (see the module
  doc) a lost table no longer loses the goal — reads rehydrate from disk. This
  still matters for cost, not correctness: without a stable owner every read
  after a table death is a file read, and the cache is rebuilt one session at
  a time.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

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
        goal: snap.goal,
        goal_id: snap.goal_id,
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
