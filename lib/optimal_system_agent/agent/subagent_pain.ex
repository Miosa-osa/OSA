defmodule OptimalSystemAgent.Agent.SubagentPain do
  @moduledoc """
  The structured pain channel a delegated subagent (any recursion depth) uses
  to tell its PARENT something is wrong — before it either recovers on its own
  or burns all the way through its own spend/turn cap in silence.

  ## Why this exists (VSM item 9 — every subagent is itself a viable system)

  Before this, a subagent's only way of surfacing trouble was to run all the
  way to one of its OWN hard limits (`Loop.Limits.budget_exceeded?`, its turn
  cap, or the orchestrator's stall-watcher hard-stop) and stop — the parent
  found out only when the child's result came back, however that turned out.
  A stuck or runaway child therefore either finished, timed out, or burned its
  entire spend cap before anyone — the parent agent OR the human watching it —
  heard a word about it.

  `report/5` is the single, structured shape every pain signal takes:

    * `cause`    — what is wrong (`:stalled`, `:stall_hard_stop`,
      `:budget_approaching`, `:budget_exceeded`, `:spot_check_failed`).
    * `severity` — `:warning` (recoverable / advisory, does not itself stop
      anything) or `:critical` (the child is being stopped, or its own result
      cannot be vouched for).

  It fans out on the SAME two channels every other orchestrator lifecycle
  event already uses — `Events.Bus` (`:system_event`, for telemetry/CLI) and
  the `osa:session:<parent_id>` PubSub topic (for the TUI and, via
  `Agent.BackgroundNotifier`, for re-entry into the parent's OWN conversation
  as a `<task-notification>`) — so a stuck child surfaces to both the parent
  model and the human watching it quickly, not just whenever it finally
  settles.

  ## Dedupe

  A cause can legitimately recur every poll (an unresolved stall, a budget
  that stays over 80%) — the CALLER is not expected to debounce it itself.
  `report/5` self-throttles: at most one report per `{parent_id, agent_id,
  cause}` per `cooldown_ms` (default 60s, mirrors the stall watcher's own
  report backoff), so a caller can call it on every tick and the parent still
  only hears about a standing condition at a sane cadence.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  @type cause ::
          :stalled
          | :stall_hard_stop
          | :budget_approaching
          | :budget_exceeded
          | :spot_check_failed

  @type severity :: :warning | :critical

  @dedupe_table :osa_subagent_pain_dedupe
  @default_cooldown_ms 60_000

  @doc """
  Report a structured pain event from `subagent_id` to its parent `parent_id`.

  Options:

    * `:display_name` — the `@name` handle shown in the TUI (defaults to
      `subagent_id`).
    * `:role`          — the subagent's role/agent-definition name.
    * `:detail`         — a small, cause-specific map (e.g. `%{spent:, cap:}`
      for a budget cause, `%{stalled_ms:}` for a stall cause) carried on the
      event for consumers that want the raw numbers.
    * `:message`        — override the default human-readable summary.
    * `:cooldown_ms`    — override the dedupe window (default 60s).

  Always returns `:ok` — a pain report must never be able to raise into the
  caller (budget/stall observation code, in particular, must keep running
  even if telemetry is unavailable).
  """
  @spec report(String.t(), String.t(), cause(), severity(), keyword()) :: :ok
  def report(parent_id, subagent_id, cause, severity, opts \\ [])

  def report(parent_id, subagent_id, cause, severity, opts)
      when is_binary(parent_id) and is_binary(subagent_id) and severity in [:warning, :critical] do
    cooldown = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)

    if throttled?({parent_id, subagent_id, cause}, cooldown) do
      :ok
    else
      emit(parent_id, subagent_id, cause, severity, opts)
    end
  rescue
    e ->
      Logger.debug("[SubagentPain] report failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def report(_parent_id, _subagent_id, _cause, _severity, _opts), do: :ok

  defp emit(parent_id, subagent_id, cause, severity, opts) do
    display_name = Keyword.get(opts, :display_name) || subagent_id
    role = Keyword.get(opts, :role)
    detail = Keyword.get(opts, :detail, %{})
    message = Keyword.get(opts, :message) || default_message(cause, display_name, detail)

    payload = %{
      event: :subagent_pain,
      session_id: parent_id,
      agent_id: subagent_id,
      display_name: display_name,
      role: role,
      cause: cause,
      severity: severity,
      detail: detail,
      message: message
    }

    Bus.emit(:system_event, payload)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{parent_id}",
      {:osa_event, Map.put(payload, :type, :subagent_pain)}
    )

    Logger.info(
      "[SubagentPain] #{subagent_id} -> #{parent_id}: #{cause}/#{severity} — #{message}"
    )

    :ok
  end

  # ── Dedupe ──────────────────────────────────────────────────────────

  defp throttled?(key, cooldown_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@dedupe_table, key) do
      [{^key, last}] when now - last < cooldown_ms ->
        true

      _ ->
        :ets.insert(@dedupe_table, {key, now})
        false
    end
  rescue
    _ -> false
  end

  defp ensure_table do
    case :ets.whereis(@dedupe_table) do
      :undefined ->
        try do
          :ets.new(@dedupe_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc false
  @spec reset_dedupe() :: :ok
  def reset_dedupe do
    ensure_table()
    :ets.delete_all_objects(@dedupe_table)
    :ok
  rescue
    _ -> :ok
  end

  # ── Default messages ──────────────────────────────────────────────────

  defp default_message(:stalled, name, detail),
    do: "@#{name} is stalled#{minutes_suffix(detail)} — check task_output."

  defp default_message(:stall_hard_stop, name, detail),
    do: "@#{name} was auto-stopped after no progress#{minutes_suffix(detail)}."

  defp default_message(:budget_approaching, name, detail),
    do: "@#{name} is approaching its spend cap#{cap_suffix(detail)}."

  defp default_message(:budget_exceeded, name, detail),
    do: "@#{name} exceeded its spend cap#{cap_suffix(detail)} and is aborting."

  defp default_message(:spot_check_failed, name, detail),
    do: "@#{name}'s own result failed a spot-check#{reason_suffix(detail)}."

  defp default_message(cause, name, _detail), do: "@#{name} reported pain: #{cause}"

  defp minutes_suffix(%{stalled_ms: ms}) when is_integer(ms), do: " for #{div(ms, 60_000)}m"
  defp minutes_suffix(_), do: ""

  defp cap_suffix(%{spent: spent, cap: cap}) when is_number(spent) and is_number(cap),
    do: " ($#{Float.round(spent * 1.0, 2)} / $#{Float.round(cap * 1.0, 2)})"

  defp cap_suffix(_), do: ""

  defp reason_suffix(%{reason: reason}) when is_binary(reason), do: ": #{reason}"
  defp reason_suffix(_), do: ""
end
