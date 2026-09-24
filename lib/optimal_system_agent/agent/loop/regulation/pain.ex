defmodule OptimalSystemAgent.Agent.Loop.Regulation.Pain do
  @moduledoc """
  The algedonic (pain) channel (item 1) — one unified per-turn score, with a
  severity and a plain-language cause, computed from `Signals` and the
  `Homeostat`'s cost/error bands.

  `Events.Bus.emit_algedonic/3` already exists (used by teams cost tracking,
  self-healing, and verification) but the ReAct loop never called it. This is
  that call site: the turn-level detectors that used to only halt or log now
  also feed ONE pain score, which is:

    * surfaced to the user immediately — a rate-limited algedonic emission
      plus a direct `osa:session:<id>` broadcast the TUI renders as a
      distinct row (`Agent.Loop.Regulation.PainChannel` owns the rate limit;
      see its moduledoc for why a severity increase always bypasses it);
    * used to steer the turn BEFORE it needs to halt — at `:high` severity
      caused by ambiguity (repeated re-verification, contradicted
      expectations), `Regulation.Question` is asked to inject a single
      "stop and ask" directive instead of continuing silently (item 14);
    * used to actually pause the turn at `:critical` severity, handing
      control back to the user — a `{:halt, message, state}` the caller marks
      `:control` (a deliberate stop, not a guard's private note — see
      `TerminalSource`), exactly like the existing auto-mode pause.

  Severity bands and the question/pause score thresholds are configurable
  under `config :optimal_system_agent, :regulation_pain`.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly
  alias OptimalSystemAgent.Agent.Loop.Regulation.Homeostat
  alias OptimalSystemAgent.Agent.Loop.Regulation.PainChannel
  alias OptimalSystemAgent.Agent.Loop.Regulation.Question
  alias OptimalSystemAgent.Agent.Loop.Regulation.Signals
  alias OptimalSystemAgent.Events.Bus

  @type severity :: :none | :low | :medium | :high | :critical

  # Component weights. They deliberately do not sum to 1.0 — several strong
  # signals firing together SHOULD be able to push the score to the ceiling
  # (clamped in `score/2`), because that really is a worse turn than any one
  # signal alone.
  @w_probe 0.25
  @w_reasoning_only 0.20
  @w_stall 0.15
  @w_recovery 0.10
  @w_escalation 0.10
  @w_reasoning_overflow 0.10
  @w_surprise 0.10
  @w_wait 0.10
  @w_homeostat 0.15

  @stall_checkpoint_denominator 2
  @surprise_denominator 3

  @doc """
  Score this iteration, surface the result, and decide whether to steer
  (inject a single question) or pause the turn.

  `signals` / `homeostat_report` are the outputs the caller already computed
  this iteration (`Signals.collect/3`, `Homeostat.regulate/4`) — passed in so
  this module never recomputes, and never re-triggers, `PainChannel`'s
  wait-time reset.
  """
  @spec evaluate(map(), Signals.t(), Homeostat.report()) ::
          {:ok, map()} | {:halt, String.t(), map()}
  def evaluate(state, signals, homeostat_report) do
    if enabled?() do
      score = score(signals, homeostat_report)
      severity = severity_for(score)
      cause = cause_text(signals, homeostat_report)
      session_id = Map.get(state, :session_id)

      surface(session_id, severity, score, cause)

      state
      |> maybe_clear_alert(session_id, severity)
      |> decide(severity, score, cause, signals)
    else
      {:ok, state}
    end
  end

  # ── Scoring ──────────────────────────────────────────────────────────────

  defp score(signals, homeostat_report) do
    probe_component =
      @w_probe * min(1.0, signals.probe_streak / IdenticalCall.windowed_halt_threshold())

    reasoning_only_component =
      @w_reasoning_only * min(1.0, signals.reasoning_only_streak / ReasoningOnly.threshold())

    stall_component =
      @w_stall * min(1.0, signals.stall_checkpoints / @stall_checkpoint_denominator)

    recovery_component = @w_recovery * signals.recovery_ratio
    escalation_component = @w_escalation * signals.escalation_ratio
    overflow_component = if signals.reasoning_overflow_ms, do: @w_reasoning_overflow, else: 0.0
    surprise_component = @w_surprise * min(1.0, signals.surprises / @surprise_denominator)
    wait_component = @w_wait * min(1.0, signals.wait_ms / wait_alarm_ms())

    homeostat_component =
      @w_homeostat *
        (if(homeostat_report.cost.band == :high, do: 0.5, else: 0.0) +
           if homeostat_report.error.band == :high, do: 0.5, else: 0.0)

    total =
      probe_component + reasoning_only_component + stall_component + recovery_component +
        escalation_component + overflow_component + surprise_component + wait_component +
        homeostat_component

    min(1.0, Float.round(total, 3))
  end

  defp severity_for(score) do
    cond do
      score >= pause_at() -> :critical
      score >= question_at() -> :high
      score >= medium_at() -> :medium
      score >= low_at() -> :low
      true -> :none
    end
  end

  # ── Cause — the plain-language explanation the incident report asked for ──

  defp cause_text(signals, homeostat_report) do
    cond do
      signals.probe_streak >= 3 ->
        "#{signals.probe_streak} #{if signals.probe_tool, do: "`#{signals.probe_tool}`", else: "read-only"} " <>
          "probes, #{edits_clause(signals)}, #{fmt_duration(signals.elapsed_ms)} — " <>
          "re-verifying the same thing"

      signals.reasoning_only_streak >= 2 ->
        "#{signals.reasoning_only_streak} reasoning-only generations in a row with no tool " <>
          "calls, #{fmt_duration(signals.elapsed_ms)} elapsed"

      signals.reasoning_overflow_ms ->
        "a single reasoning call ran #{fmt_duration(signals.reasoning_overflow_ms)} and produced nothing"

      homeostat_report.cost.band == :high ->
        "$#{:erlang.float_to_binary(homeostat_report.cost.value * 1.0, decimals: 2)} spent this " <>
          "turn with nothing changed on disk"

      homeostat_report.error.band == :high ->
        "#{round(homeostat_report.error.ratio * 100)}% of recent tool calls are erroring"

      signals.recovery_ratio >= 0.5 ->
        "#{signals.recovery_attempts} failure-recovery attempts spent this turn"

      signals.wait_ms >= wait_alarm_ms() ->
        "#{fmt_duration(signals.wait_ms)} spent waiting on an approval"

      signals.surprises > 0 ->
        "#{signals.surprises} tool call(s) did not do what issuing them implied"

      signals.escalation_ratio >= 0.5 ->
        "repeated nudges to change approach without a change in outcome"

      true ->
        "elevated pain with no single dominant cause"
    end
  end

  defp edits_clause(%{no_disk_change?: true}), do: "no edits"
  defp edits_clause(_), do: "edits made"

  # ── Surfacing (item 1: "surface it to the user immediately, not just the log") ──

  defp surface(_session_id, :none, _score, _cause), do: :ok

  defp surface(session_id, severity, score, cause) when is_binary(session_id) do
    if PainChannel.should_emit?(session_id, severity, min_emit_interval_ms()) do
      PainChannel.record_emit(session_id, severity)

      message = "stuck: #{cause}"

      Bus.emit_algedonic(bus_severity(severity), message,
        source: "regulation.pain",
        metadata: %{session_id: session_id, score: score, cause: cause}
      )

      broadcast(session_id, severity, score, message)
    end

    :ok
  end

  defp surface(_session_id, _severity, _score, _cause), do: :ok

  defp broadcast(session_id, severity, score, message) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :system_event,
         event: :pain_alert,
         session_id: session_id,
         severity: to_string(severity),
         score: score,
         message: message
       }}
    )
  end

  # A turn that just dropped back to :none, having shown ANY alert before
  # (:low counts — `surface/4` shows a row for it too), clears the TUI row —
  # otherwise a resolved stall would leave a stale alarm on screen for the
  # rest of the turn (the client has no TTL of its own; see `PainChannel`'s
  # moduledoc on why emission itself is rate-limited but a clear must never
  # be). Dropping only as far as `:low` is not cleared here — that band still
  # shows its own (rate-limited) alert, so there is nothing stale to remove.
  defp maybe_clear_alert(state, session_id, :none) do
    if Map.get(state, :regulation_last_reported_severity) not in [nil, :none] and
         is_binary(session_id) do
      broadcast(session_id, :none, 0.0, "")
    end

    Map.put(state, :regulation_last_reported_severity, :none)
  end

  defp maybe_clear_alert(state, _session_id, severity),
    do: Map.put(state, :regulation_last_reported_severity, severity)

  defp bus_severity(:critical), do: :critical
  defp bus_severity(:high), do: :high
  defp bus_severity(_), do: :medium

  # ── Decide: continue / ask one question / pause ───────────────────────────

  defp decide(state, :critical, score, cause, _signals) do
    message =
      "Pausing here: #{cause}. This looked like the turn was #{grinding_verb(score)} rather " <>
        "than converging, so I'm stopping and handing back control instead of continuing " <>
        "unattended. Tell me how you'd like to proceed, or ask me to keep going if this is " <>
        "expected."

    {:halt, message, state}
  end

  defp decide(state, :high, _score, cause, signals) do
    if ambiguity_cause?(signals) do
      {:ok, Question.maybe_inject(state, cause)}
    else
      {:ok, state}
    end
  end

  defp decide(state, _severity, _score, _cause, _signals), do: {:ok, state}

  defp ambiguity_cause?(signals), do: signals.probe_streak >= 3 or signals.surprises >= 2

  defp grinding_verb(score) when score >= 0.95, do: "badly stuck"
  defp grinding_verb(_), do: "stuck"

  # ── Duration formatting (turn-clock scale: seconds to tens of minutes) ────

  defp fmt_duration(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

  defp fmt_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m#{seconds}s"
  end

  defp fmt_duration(_), do: "0s"

  # ── Config ────────────────────────────────────────────────────────────────

  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp question_at, do: Keyword.get(config(), :question_at, 0.55)
  defp pause_at, do: Keyword.get(config(), :pause_at, 0.85)
  defp medium_at, do: Keyword.get(config(), :medium_at, 0.35)
  defp low_at, do: Keyword.get(config(), :low_at, 0.15)
  defp min_emit_interval_ms, do: Keyword.get(config(), :min_emit_interval_ms, 5_000)
  defp wait_alarm_ms, do: Keyword.get(config(), :wait_alarm_ms, 60_000)
  defp config, do: Application.get_env(:optimal_system_agent, :regulation_pain, [])
end
