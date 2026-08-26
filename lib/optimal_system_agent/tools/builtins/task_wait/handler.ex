defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Handler do
  @moduledoc """
  Validation, permission checking, and execution logic for `task_wait`.

  P5 join-barrier: block until a chosen set of PREVIOUSLY-BACKGROUNDED agent
  ids finish (or a timeout elapses), then return their results. This is
  ADDITIVE to OSA's existing poll-free background-completion notification
  (`Orchestrator.run_background/2` + `reminders.ex`'s `<task-notification>`
  injection) — not a replacement. Background dispatch already tells the model
  not to poll because completion is injected automatically; `task_wait` exists
  for the narrower case where the model has launched several agents early and
  now needs to actively converge/join on a chosen subset before proceeding,
  rather than waiting for notifications to trickle in one at a time.

  Split mirrors `TaskResume.Handler` / `Delegate.Handler`:
    * `validate/2`          — type-check input shape (cheap, no I/O)
    * `check_permissions/2` — deny once the blocking-wait nesting ceiling
      (`TaskWait.Depth`) would be exceeded
    * `execute/2`           — poll `RunStore` until every (or any, see
      `require_all`) requested agent reaches a terminal state or the timeout
      elapses, then format their results
  """

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.TaskWait.Depth
  alias OptimalSystemAgent.Tools.UseContext

  @terminal_statuses [:completed, :failed, :cancelled]
  @poll_interval_ms 500

  # Default wait bound = the shared agent-LIFETIME backstop, which is measured in
  # DAYS (see Orchestrator.@default_subagent_timeout_ms / :subagent_join_timeout_ms).
  # Long-running agents run for days, so a minute-scale default spuriously "timed
  # out" on healthy agents and drove the coordinator into a re-poll loop. Reading
  # the same knob means task_wait, the delegate join, and the swarm patterns all
  # agree on one days-scale number with no stray cap. A caller that wants a
  # deliberately short bound still passes an explicit `timeout_ms`, and the
  # timeout branch treats a still-running agent as healthy (not a dead end).
  defp default_timeout_ms,
    do: OptimalSystemAgent.Orchestrator.subagent_join_timeout_ms(%{})

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"agent_ids" => ids} = input, _ctx) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
      {:ok, input}
    else
      {:error, "agent_ids must be an array of non-empty strings", -32_602}
    end
  end

  def validate(%{"agent_ids" => _}, _ctx),
    do: {:error, "agent_ids must be a non-empty array of strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: agent_ids", -32_602}

  # ── Stage 2: Permission check ───────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, ctx) do
    caller_id = session_id(ctx)
    # +1 for the wait this call is about to register — the check must reject
    # BEFORE blocking, not discover the ceiling was exceeded mid-wait.
    depth = Depth.current_depth(caller_id) + 1

    if depth > Depth.max_depth() do
      {:deny,
       "Access denied: blocking-wait nesting depth #{depth} would exceed the configured " <>
         "ceiling (#{Depth.max_depth()}) — an agent that is itself being blocking-waited-on " <>
         "cannot nest another blocking wait this deep (deadlock/starvation guard). Use " <>
         "background dispatch + the automatic completion notification instead of nesting " <>
         "more joins."}
    else
      {:allow, input}
    end
  end

  # ── Stage 3: Execute ────────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"agent_ids" => agent_ids} = input, ctx) do
    caller_id = session_id(ctx)
    require_all = Map.get(input, "require_all", true) != false
    timeout_ms = parse_timeout_ms(Map.get(input, "timeout_ms")) || default_timeout_ms()
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Depth.enter(caller_id)

    try do
      runs = poll(agent_ids, require_all, deadline)
      {:ok, format_results(agent_ids, runs, require_all)}
    after
      Depth.exit_wait(caller_id)
    end
  rescue
    e -> {:error, "task_wait failed: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: agent_ids"}

  # ── Private ──────────────────────────────────────────────────────────────

  defp poll(agent_ids, require_all, deadline) do
    runs = Map.new(agent_ids, fn id -> {id, RunStore.get(id)} end)

    satisfied? =
      if require_all,
        do: Enum.all?(runs, fn {_id, run} -> terminal?(run) end),
        else: Enum.any?(runs, fn {_id, run} -> terminal?(run) end)

    cond do
      satisfied? ->
        runs

      System.monotonic_time(:millisecond) >= deadline ->
        runs

      true ->
        Process.sleep(@poll_interval_ms)
        poll(agent_ids, require_all, deadline)
    end
  end

  # An unknown id (typo, never launched) is treated as terminal so a single
  # bad id can't block the join forever — it is surfaced in the formatted
  # output as "no run found" instead.
  defp terminal?(nil), do: true
  defp terminal?(%{status: status}), do: status in @terminal_statuses
  defp terminal?(_), do: true

  defp format_results(agent_ids, runs, require_all) do
    sections = Enum.map(agent_ids, &format_one(&1, Map.get(runs, &1)))
    mode = if require_all, do: "ALL", else: "ANY"

    still_running =
      agent_ids
      |> Enum.filter(fn id -> match?(%{status: :running}, Map.get(runs, id)) end)

    header =
      if still_running == [] do
        "Join-barrier wait finished (mode=#{mode}) for #{length(agent_ids)} agent(s):"
      else
        # Timed out with work still in flight. This is NOT a failure and the
        # coordinator must NOT re-issue task_wait — background completion is
        # delivered automatically as a task-notification. Say so explicitly, or
        # the model falls back into the 10-minute re-poll loop this fix removes.
        "Join-barrier TIMED OUT with #{length(still_running)} of #{length(agent_ids)} " <>
          "agent(s) still running: #{Enum.map_join(still_running, ", ", &short_name/1)}. " <>
          "They are healthy, not failed — do NOT wait on them again. Their results will be " <>
          "delivered to you automatically when they finish; continue with other work now."
      end

    Enum.join([header | sections], "\n\n")
  end

  # Clean, human handle for a subagent id: the trailing name segment of
  # `agent:session-<ts>-<hash>:name`, never the raw session gibberish.
  defp short_name(id) when is_binary(id), do: id |> String.split(":") |> List.last()
  defp short_name(id), do: to_string(id)

  defp format_one(id, nil) do
    "### #{short_name(id)}\nNo run found for this agent id — nothing to join on."
  end

  defp format_one(id, %{status: :running} = run) do
    "### #{short_name(id)} (#{run.role}) — still running\n" <>
      "Latest progress: #{Enum.join(run.recent_actions, "; ")}\n" <>
      "(Not finished yet — its completion will be delivered automatically; do not re-wait.)"
  end

  defp format_one(id, run) do
    summary =
      case run.result do
        %{summary: s} when is_binary(s) and s != "" -> s
        _ -> "(no summary)"
      end

    resumed_note =
      if Map.get(run, :resumed_from), do: " (resumed_from=#{run.resumed_from})", else: ""

    "### #{short_name(id)} (#{run.role})#{resumed_note} — #{run.status}\n#{summary}"
  end

  defp parse_timeout_ms(nil), do: nil
  defp parse_timeout_ms(ms) when is_integer(ms) and ms > 0, do: ms

  defp parse_timeout_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_timeout_ms(_), do: nil

  defp session_id(%UseContext{session_id: sid}) when is_binary(sid), do: sid
  defp session_id(ctx) when is_map(ctx), do: Map.get(ctx, :session_id) || "unknown"
  defp session_id(_), do: "unknown"
end
