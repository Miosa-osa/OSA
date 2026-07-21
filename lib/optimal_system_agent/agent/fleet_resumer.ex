defmodule OptimalSystemAgent.Agent.FleetResumer do
  @moduledoc """
  W3/D3 — boot-time orphan recovery for autonomous fleets.

  When the daemon crashes or is restarted, every in-flight subagent loop dies
  with it. Their `RunStore` rows survive (in a shared ETS table, or rehydrated
  from `~/.osa/agent-runs/*.md`) still reading `:running`, but the processes are
  gone — so live fleet descendants are never resumed and the roster/counts are
  inflated by ghosts.

  This module is the single boot entry (`resume_on_boot/1`, called from the
  application supervisor AFTER `RunStore.init_store/0`) that:

    1. Selects the orphaned `:running` runs that are safe to re-dispatch —
       autonomous posture, owning process gone — budget-capped
       (`selection/2` / `qualifying_orphans/2`). The parent chain is walked so a
       parent resumes before its descendants (root-first ordering).
    2. Re-dispatches each qualifying orphan through the EXISTING resume
       mechanism (`Orchestrator.resume_subagent/2`), which restarts the run
       under its original agent id with its full saved transcript — i.e. a
       subtree resume built from the durable per-node `task_resume` snapshots.
    3. Reconciles whatever stays stale (`RunStore.reconcile_stale_running/1`),
       marking those rows terminal so counts settle. Runs just re-dispatched are
       alive again and are therefore skipped by the reconcile.

  ## Opt-in and budget

  Re-dispatch is **opt-in** and safe-by-default: it only runs when the app-env
  flag `:fleet_resume_on_boot` is truthy (default `false`). Reconciliation of
  stale rows ALWAYS runs at boot regardless of the flag, since inflated counts
  are never desirable. The number of runs re-dispatched in one boot is capped by
  `:fleet_resume_max` (default `#{10}`) so a large dead fleet cannot stampede the
  node on restart.

  ## v1 durability limitation (documented, intentional)

  Only STARTED nodes are durable. A workflow item that was QUEUED but had not yet
  begun executing when the crash happened has no `RunStore` row and no saved
  transcript, so it CANNOT be recovered here — it is lost in v1. The resumer
  `Logger.warning`s a best-effort note when it observes such gaps rather than
  pretending the queued work ran. Recovering not-yet-started queue items would
  require durably persisting the pending workflow queue itself, which is out of
  scope for W3/D3.
  """

  require Logger

  alias OptimalSystemAgent.Agent.RunStore

  # Default per-boot cap on how many orphaned runs are re-dispatched.
  @default_max 10

  # Fixed continuation message seeded into a resumed orphan. Kept generic; the
  # run's full prior transcript is restored by resume_subagent, so this only has
  # to nudge it to continue.
  @resume_message "[fleet-resume] The daemon restarted while this task was in " <>
                    "flight. Your full prior context has been restored — continue " <>
                    "from where you left off and finish the task."

  @doc """
  Boot entry point. Reconciles stale `:running` rows and, when opted in,
  re-dispatches qualifying orphaned runs. Returns a summary map. Never raises.

  Options (all injectable — production defaults resolve from app-env / registry):

    * `:enabled`    — override the `:fleet_resume_on_boot` flag.
    * `:runs`       — the candidate run list (default `RunStore.all_running/0`).
    * `:alive_fun`  — liveness probe `(agent_id -> boolean)`.
    * `:posture_fun`— posture probe `(run -> boolean)` (autonomous?).
    * `:budget`     — max runs to re-dispatch (default `:fleet_resume_max`).
    * `:resume_fun` — `(agent_id, message -> {:ok, term} | {:error, term})`,
      default `Orchestrator.resume_subagent/2`. Injectable so selection can be
      tested without booting real loops.
  """
  @spec resume_on_boot(keyword()) :: %{
          enabled: boolean(),
          resumed: [String.t()],
          failed: [String.t()],
          reconciled: [String.t()]
        }
  def resume_on_boot(opts \\ []) do
    enabled = Keyword.get(opts, :enabled, enabled?())
    alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)

    {resumed, failed} =
      if enabled do
        candidates = Keyword.get_lazy(opts, :runs, &RunStore.all_running/0)

        selected =
          qualifying_orphans(candidates,
            alive_fun: alive_fun,
            posture_fun: Keyword.get(opts, :posture_fun, &default_autonomous?/1),
            budget: Keyword.get(opts, :budget, max_resumes())
          )

        warn_queued_gap(candidates, selected)
        dispatch(selected, resume_fun(opts))
      else
        {[], []}
      end

    # Reconcile stale rows AFTER re-dispatch so the just-resumed runs (now alive)
    # are skipped and only true ghosts are marked terminal.
    reconciled =
      RunStore.reconcile_stale_running(alive_fun: alive_fun)
      |> Enum.map(& &1.agent_id)

    summary = %{enabled: enabled, resumed: resumed, failed: failed, reconciled: reconciled}

    Logger.info(
      "[FleetResumer] boot recovery: enabled=#{enabled} resumed=#{length(resumed)} " <>
        "failed=#{length(failed)} reconciled=#{length(reconciled)}"
    )

    summary
  rescue
    e ->
      Logger.warning("[FleetResumer] boot recovery failed: #{Exception.message(e)}")
      %{enabled: false, resumed: [], failed: [], reconciled: []}
  end

  @doc """
  Pure selection: which `:running` runs qualify for boot re-dispatch.

  A run qualifies when it is `:running`, its owning process is gone (crash
  orphan, not a currently-live run) and it was dispatched under an autonomous
  posture. Results are ordered root-first (walking the `parent_session_id` chain
  within the candidate set) so parents resume before their descendants, then
  truncated to `:budget`.

  Options: `:alive_fun`, `:posture_fun`, `:budget` (see `resume_on_boot/1`).
  Deterministic and side-effect free — the unit-test seam for W3.
  """
  @spec qualifying_orphans([RunStore.run()], keyword()) :: [RunStore.run()]
  def qualifying_orphans(runs, opts \\ []) when is_list(runs) do
    alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)
    posture_fun = Keyword.get(opts, :posture_fun, &default_autonomous?/1)
    budget = Keyword.get(opts, :budget, max_resumes())

    runs
    |> Enum.filter(fn r -> Map.get(r, :status) == :running end)
    |> Enum.reject(fn r -> invoke_bool(alive_fun, r.agent_id) end)
    |> Enum.filter(fn r -> invoke_bool(posture_fun, r) end)
    |> order_root_first()
    |> take_budget(budget)
  end

  # Root-first: a run whose parent is ALSO in the set sorts after its parent.
  # Depth = number of ancestors reachable via parent_session_id inside the set.
  defp order_root_first(runs) do
    by_id = Map.new(runs, fn r -> {r.agent_id, r} end)

    Enum.sort_by(runs, fn r ->
      {chain_depth(r, by_id, 0), DateTime.to_unix(r.started_at, :millisecond)}
    end)
  end

  defp chain_depth(run, by_id, acc) when acc < 1000 do
    case Map.get(by_id, Map.get(run, :parent_session_id)) do
      nil -> acc
      parent -> chain_depth(parent, by_id, acc + 1)
    end
  end

  defp chain_depth(_run, _by_id, acc), do: acc

  defp take_budget(runs, budget) when is_integer(budget) and budget >= 0,
    do: Enum.take(runs, budget)

  defp take_budget(runs, _), do: runs

  defp dispatch(runs, resume_fun) do
    Enum.reduce(runs, {[], []}, fn run, {ok, err} ->
      case invoke_resume(resume_fun, run.agent_id) do
        {:ok, _} ->
          Logger.info("[FleetResumer] re-dispatched orphan #{run.agent_id}")
          {[run.agent_id | ok], err}

        {:error, reason} ->
          Logger.warning(
            "[FleetResumer] resume failed for #{run.agent_id}: #{inspect(reason)}"
          )

          {ok, [run.agent_id | err]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  defp invoke_resume(fun, agent_id) do
    fun.(agent_id, @resume_message)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # v1 durability note: candidates that are :running but were never actually
  # started leave no resumable snapshot. We can't enumerate not-yet-started
  # QUEUED items (they have no row at all), but we surface the count of running
  # orphans we chose NOT to resume so the drop is logged, not silent.
  defp warn_queued_gap(candidates, selected) do
    running = Enum.count(candidates, fn r -> Map.get(r, :status) == :running end)
    dropped = running - length(selected)

    if dropped > 0 do
      Logger.warning(
        "[FleetResumer] #{dropped} in-flight run(s) not re-dispatched (non-autonomous, " <>
          "still-alive, or over budget); any QUEUED-but-unstarted workflow items are " <>
          "lost in v1 (only started nodes are durable)."
      )
    end

    :ok
  end

  # ── posture / liveness resolution ─────────────────────────────────────────

  # Autonomous iff the run records an autonomous posture (on the row, else in
  # its saved messages meta). Safe-by-default: unknown posture => NOT autonomous,
  # so an ambiguous run is reconciled rather than silently re-run unattended.
  @doc false
  def default_autonomous?(run) do
    posture = Map.get(run, :posture) || meta_posture(run)
    posture in [:autonomous, "autonomous"]
  end

  defp meta_posture(run) do
    case RunStore.load_messages(Map.get(run, :agent_id) || "") do
      {:ok, _messages, meta} when is_map(meta) -> Map.get(meta, :posture)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp default_alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != []
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp resume_fun(opts) do
    Keyword.get(opts, :resume_fun, &OptimalSystemAgent.Orchestrator.resume_subagent/2)
  end

  defp invoke_bool(fun, arg) do
    fun.(arg) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp enabled? do
    Application.get_env(:optimal_system_agent, :fleet_resume_on_boot, false) == true
  end

  defp max_resumes do
    case Application.get_env(:optimal_system_agent, :fleet_resume_max, @default_max) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max
    end
  end
end
