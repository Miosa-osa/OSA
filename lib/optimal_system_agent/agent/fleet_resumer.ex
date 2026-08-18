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

  ## Cross-process safety (the reason this module cannot trust `alive_fun`)

  `resume_on_boot/1` runs at EVERY BEAM boot, and every `osa` invocation is its
  own BEAM. `RunStore.rehydrate/0` reads the machine-global `~/.osa/agent-runs`,
  so a second invocation's index is seeded with the FIRST invocation's live
  `:running` rows — and the `SessionRegistry` probe, being node-local, reports
  every one of them as dead. Unguarded, that made a second `osa` both
  re-dispatch (duplicate execution) and cancel (`reconcile_stale_running/1`)
  another process's healthy in-flight runs.

  So "dead" is never inferred from a registry lookup alone. A run is a candidate
  only if this process could take its `RunStore` **ownership lease**
  (`lease_claimable?/1` — read-only, keeps selection side-effect free), and the
  lease is actually **acquired immediately before** the re-dispatch, not merely
  at selection time. A run owned by another live process is skipped in both
  phases. Reconciliation is gated the same way inside
  `RunStore.reconcile_stale_running/1`.

  ## Recovery policy and budget

  Re-dispatch is enabled by default for autonomous runs and can be disabled with
  the app-env flag `:fleet_resume_on_boot`. Reconciliation of
  stale rows ALWAYS runs at boot regardless of the flag, since inflated counts
  are never desirable — note that the flag has never gated the cancellation half
  (the `if enabled` in `resume_on_boot/1` closes before it), so before the
  ownership lease existed, turning fleet-resume OFF suppressed the duplicate
  dispatch but NOT the cross-process cancellation. It is the lease, not the
  flag, that makes the unconditional reconcile safe. The number of runs
  re-dispatched in one boot is capped by
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

  alias OptimalSystemAgent.Agent.{ExecutionControl, RunStore}

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
    * `:claimable_fun` — read-only ownership probe used for SELECTION, default
      `RunStore.lease_claimable?/1`.
    * `:claim_fun`  — ownership ACQUISITION used immediately before dispatch and
      before reconciliation, default `RunStore.claim_lease/1`.

  `:skipped` in the summary lists runs that were dropped because another live
  process owns them.
  """
  @spec resume_on_boot(keyword()) :: %{
          enabled: boolean(),
          resumed: [String.t()],
          failed: [String.t()],
          skipped: [String.t()],
          reconciled: [String.t()]
        }
  def resume_on_boot(opts \\ []) do
    enabled = Keyword.get(opts, :enabled, enabled?())
    alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)
    claim_fun = Keyword.get(opts, :claim_fun, &RunStore.claim_lease/1)

    {resumed, failed, skipped} =
      if enabled do
        candidates = Keyword.get_lazy(opts, :runs, &RunStore.all_running/0)
        claimable_fun = Keyword.get(opts, :claimable_fun, &RunStore.lease_claimable?/1)

        selected =
          qualifying_orphans(candidates,
            alive_fun: alive_fun,
            posture_fun: Keyword.get(opts, :posture_fun, &default_autonomous?/1),
            claimable_fun: claimable_fun,
            budget: Keyword.get(opts, :budget, max_resumes())
          )

        warn_queued_gap(candidates, selected)
        {resumed, failed, lost_in_flight} = dispatch(selected, resume_fun(opts), claim_fun)

        # Runs another process owns are dropped in two places — at selection (the
        # read-only probe) and again at dispatch (if ownership changed in between).
        # Report both, so "skipped because someone else owns it" is never silent.
        {resumed, failed, foreign(candidates, claimable_fun) ++ lost_in_flight}
      else
        {[], [], []}
      end

    # Reconcile stale rows AFTER re-dispatch so the just-resumed runs (now alive)
    # are skipped and only true ghosts are marked terminal. The reconcile takes
    # the ownership lease itself, so a run owned by another live `osa` process is
    # left strictly alone even though our node-local `alive_fun` says it is dead.
    reconciled =
      RunStore.reconcile_stale_running(alive_fun: alive_fun, claim_fun: claim_fun)
      |> Enum.map(& &1.agent_id)

    summary = %{
      enabled: enabled,
      resumed: resumed,
      failed: failed,
      skipped: skipped,
      reconciled: reconciled
    }

    Logger.info(
      "[FleetResumer] boot recovery: enabled=#{enabled} resumed=#{length(resumed)} " <>
        "failed=#{length(failed)} skipped=#{length(skipped)} reconciled=#{length(reconciled)}"
    )

    summary
  rescue
    e ->
      Logger.warning("[FleetResumer] boot recovery failed: #{Exception.message(e)}")
      %{enabled: false, resumed: [], failed: [], skipped: [], reconciled: []}
  end

  @doc """
  Pure selection: which `:running` runs qualify for boot re-dispatch.

  A run qualifies when it is `:running`, **no other live process owns it**, its
  owning process is gone on this node (crash orphan, not a currently-live run)
  and it was dispatched under an autonomous posture. Results are ordered
  root-first (walking the `parent_session_id` chain within the candidate set) so
  parents resume before their descendants, then truncated to `:budget`.

  The ownership filter runs FIRST and is the only one that can answer the
  cross-process question; `alive_fun` merely narrows things further within this
  node. Selection uses the read-only probe — the lease itself is taken in
  `dispatch/3`, immediately before the run is restarted.

  Options: `:alive_fun`, `:posture_fun`, `:claimable_fun`, `:recoverable_fun`, `:budget` (see
  `resume_on_boot/1`). Deterministic and side-effect free — the unit-test seam
  for W3.
  """
  @spec qualifying_orphans([RunStore.run()], keyword()) :: [RunStore.run()]
  def qualifying_orphans(runs, opts \\ []) when is_list(runs) do
    alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)
    posture_fun = Keyword.get(opts, :posture_fun, &default_autonomous?/1)
    claimable_fun = Keyword.get(opts, :claimable_fun, &RunStore.lease_claimable?/1)
    recoverable_fun = Keyword.get(opts, :recoverable_fun, &default_recoverable?/1)
    budget = Keyword.get(opts, :budget, max_resumes())

    runs
    |> Enum.filter(fn r -> Map.get(r, :status) == :running end)
    |> Enum.filter(fn r -> invoke_bool(recoverable_fun, r) end)
    |> Enum.filter(fn r -> invoke_bool(claimable_fun, r.agent_id) end)
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

  # Ownership is acquired here — immediately before the re-dispatch, the only
  # moment that matters. Selection happened earlier and the world may have moved
  # since; a run another process claimed in between is skipped, never duplicated.
  # A resume that fails releases the lease again so the run is not left pinned to
  # a process that is not running it.
  defp dispatch(runs, resume_fun, claim_fun) do
    Enum.reduce(runs, {[], [], []}, fn run, {ok, err, skipped} ->
      case invoke_claim(claim_fun, run.agent_id) do
        {:ok, _} ->
          case invoke_resume(resume_fun, run.agent_id) do
            {:ok, _} ->
              Logger.info("[FleetResumer] re-dispatched orphan #{run.agent_id}")

              ExecutionControl.progress(run.agent_id, %{
                status: :running,
                recovery_state: "auto_resumed_after_backend_restart"
              })

              {[run.agent_id | ok], err, skipped}

            {:error, reason} ->
              Logger.warning(
                "[FleetResumer] resume failed for #{run.agent_id}: #{inspect(reason)}"
              )

              RunStore.release_lease(run.agent_id)

              ExecutionControl.increment(run.agent_id, :failure_count)

              ExecutionControl.progress(run.agent_id, %{
                recovery_state: "auto_resume_failed",
                last_error: inspect(reason)
              })

              {ok, [run.agent_id | err], skipped}
          end

        {:error, reason} ->
          Logger.info(
            "[FleetResumer] not resuming #{run.agent_id}: owned by another live process " <>
              "(#{inspect(reason)})"
          )

          ExecutionControl.progress(run.agent_id, %{
            recovery_state: "owned_by_another_live_backend"
          })

          {ok, err, [run.agent_id | skipped]}
      end
    end)
    |> then(fn {ok, err, skipped} ->
      {Enum.reverse(ok), Enum.reverse(err), Enum.reverse(skipped)}
    end)
  end

  # `:running` candidates that another live process demonstrably owns.
  defp foreign(candidates, claimable_fun) do
    candidates
    |> Enum.filter(fn r -> Map.get(r, :status) == :running end)
    |> Enum.reject(fn r -> invoke_bool(claimable_fun, r.agent_id) end)
    |> Enum.map(& &1.agent_id)
  end

  defp invoke_claim(fun, agent_id) do
    case fun.(agent_id) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
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

  defp default_recoverable?(run) do
    case ExecutionControl.get(run.agent_id) do
      nil -> true
      %{status: status} -> to_string(status) in ["running", "stalled"]
    end
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
    Application.get_env(:optimal_system_agent, :fleet_resume_on_boot, true) == true
  end

  defp max_resumes do
    case Application.get_env(:optimal_system_agent, :fleet_resume_max, @default_max) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max
    end
  end
end
