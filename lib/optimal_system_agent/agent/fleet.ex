defmodule OptimalSystemAgent.Agent.Fleet do
  @moduledoc """
  Full-power recursive fleet-node spawning (FleetView B2).

  A *fleet node* is a FULL-POWER OSA agent loop booted as a background sibling in
  the run tree — not the restricted delegate worker. It boots via
  `Runtime.SessionManager.ensure_loop/2` with NO `permission_tier` and NO
  `channel: :internal`, so `Loop.init` defaults to `permission_tier: :full`
  (full tools / MCP / memory / permissions). This is DELIBERATELY NOT
  `Orchestrator.run_subagent/1` (the `:subagent` / `:internal` restricted path).

  Each node is spawned as an *agent-type* (`main`, `general-purpose`,
  `code-reviewer`, …) that selects its system prompt + tool allowlist. Resolution
  order for the agent-type identity:

    1. an explicit `:system_prompt` opt (verbatim override),
    2. the existing `Agents.Registry` (AGENT.md definitions — the same registry
       the `delegate` tool resolves roles from),
    3. a minimal built-in `@fleet_agent_types` fallback table.

  Lifecycle events follow the `orchestrator_agent_*` pattern but under the
  `fleet_node_*` names (see `docs/FLEETVIEW_DESIGN.md` Part 3.2), emitted on the
  `Events.Bus` as `:system_event`s and bridged to the TUI SSE stream by
  `Events.TuiForwarder` (whose allowlist carries the three names).

  A fleet-wide total-agent cap (`:max_fleet_agents`) guards against spawn bombs —
  a per-branch delegation-depth ceiling already exists, but nothing bounded the
  whole tree.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Effort, Loop, RunStore}
  alias OptimalSystemAgent.Agent.Fleet.Journal
  alias OptimalSystemAgent.Agent.Fleet.SettingsCoverage
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Workspace.FastWorktree

  @default_max_fleet_agents 16
  # Run-lifetime kill switch: absolute ceiling on nodes a single fan_out drains.
  @default_max_fleet_total 1000
  # Per-node wall-clock ceiling for a single fan_out item. A hung node is reaped
  # (its Task killed, slot freed) and recorded as a timed-out result instead of
  # stalling the whole queue forever (the old `timeout: :infinity`). 5 minutes.
  @default_node_timeout_ms 300_000
  # Grace a cancelled node gets to wind down and reach a terminal RunStore state.
  @default_cancel_ack_ms 30_000
  # Slack on top of (node ceiling + cancel ack) for the outer async_stream
  # backstop, covering worktree creation and the RunStore poll interval, so the
  # in-task ceiling always fires first.
  @task_backstop_slack_ms 30_000
  # ≥ this many in-flight (running + queued) flips the "large fleet" warning (a
  # dim advisory in the roster header — NOT a cap).
  @large_fleet_threshold 25
  @default_agent_type "general-purpose"

  # Minimal built-in fallback registry, used only when neither an explicit
  # :system_prompt opt nor an AGENT.md definition resolves the agent-type.
  # `tools: nil` means the full toolset (no allowlist filter). Kept small on
  # purpose — real roles live in AGENT.md files loaded by Agents.Registry.
  @fleet_agent_types %{
    "general-purpose" => %{
      system_prompt:
        "You are a general-purpose OSA agent with full tool access. Complete the " <>
          "assigned task end-to-end and report concrete results (files changed, " <>
          "commands run, evidence, remaining risks).",
      tools: nil
    },
    "code-reviewer" => %{
      system_prompt:
        "You are a code-reviewer agent. Read the relevant code and report " <>
          "correctness, security, and maintainability issues. Do NOT modify files.",
      # Restricted example: read-only tools only.
      tools: ["file_read", "grep", "glob", "list_dir"]
    }
  }

  @type spawn_opts :: [
          {:agent_type, String.t()}
          | {:task, String.t()}
          | {:working_dir, String.t()}
          | {:user_id, String.t()}
          | {:node_id, String.t()}
          | {:system_prompt, String.t()}
        ]

  @doc """
  Spawn a full-power fleet node under `parent_session_id`.

  Opts:
    * `:agent_type` — agent-type identity (default `"general-purpose"`); selects
      the system prompt + tool allowlist.
    * `:task` — the message that drives the node's first turn (required to do work).
    * `:system_prompt` — verbatim system-prompt override (wins over the registry).
    * `:working_dir` — cwd for the node (defaults to the shared workspace cwd).
    * `:user_id` — owner (default `"fleet"`).
    * `:node_id` — explicit session id (default: a generated `fleet:<parent>:<n>`).

  Returns `{:ok, node_id}` or `{:error, reason}`. Refuses with
  `{:error, {:fleet_cap_reached, running, cap}}` when the fleet is at capacity.
  """
  @spec spawn_fleet_node(String.t(), spawn_opts()) :: {:ok, String.t()} | {:error, term()}
  def spawn_fleet_node(parent_session_id, opts \\ [])

  def spawn_fleet_node(parent_session_id, opts) when is_binary(parent_session_id) do
    running = running_count()
    cap = max_fleet_agents()

    if running >= cap do
      Logger.warning(
        "[Fleet] Refusing spawn — fleet at capacity (#{running}/#{cap}). " <>
          "Raise :max_fleet_agents to allow more concurrent agents."
      )

      {:error, {:fleet_cap_reached, running, cap}}
    else
      do_spawn(parent_session_id, opts)
    end
  end

  def spawn_fleet_node(_parent, _opts), do: {:error, :invalid_parent_session_id}

  @doc """
  Dynamic-workflow fan-out: spawn one full-power fleet node per `item` through a
  BOUNDED-CONCURRENCY queue-drain (FleetView B5 / `docs/FLEETVIEW_DESIGN.md`
  Part 4.2).

  Semantics mirror Claude Code's dynamic workflows:

    * `max_fleet_agents()` (default 16) nodes run concurrently; the rest QUEUE
      and drain FIFO as slots free — excess spawns never fail.
    * `max_fleet_total()` (default 1000) is a run-lifetime kill switch: items
      past that ceiling are dropped (reported as `:dropped`).
    * A `fleet_summary` Bus event is emitted at start and on every completion so
      the TUI roster header can render a live `running/cap` gauge.

  GATE: dynamic workflows require the `:ultra` effort tier. Below ultra this
  returns `{:error, :ultra_required}` (peer `spawn_fleet_node/2` stays ungated —
  it works at any effort).

  `items` may be binary tasks or per-item spawn opts (keyword lists / maps),
  merged over the shared `opts` and handed to the full-power spawn path.

  Opts:
    * `:isolation` — `:worktree` runs EACH item's node in its OWN CoW git
      worktree (via `Workspace.FastWorktree`) so parallel nodes editing files
      never collide with each other or the main tree. The node's `:working_dir`
      is pointed at its worktree and the branch is recorded as the result's
      `worktree_ref` (+ durably on the RunStore run via
      `attach_worktree_snapshot/2`). Best-effort: if worktree creation fails the
      item falls back to non-isolated (a logged warning, `worktree_ref: nil`) —
      never crashing the workflow. Omit (default) to keep today's shared-cwd
      behavior.
    * `:spawn_fun` — 2-arity `(parent, opts) -> {:ok, id} | {:error, term}`
      override for the per-item spawn (defaults to `spawn_fleet_node/2`; used to
      exercise the queue-drain without booting real loops).
    * `:worktree_fun` — 2-arity `(parent, item_opts) -> {:ok, %{path, branch}} |
      {:error, term}` override for isolated worktree creation (defaults to
      `FastWorktree.create/2`; lets tests inject fake refs without real git).
    * `:await_fun` — 1-arity `(node_id) -> terminal_status` override for the
      per-item COMPLETION WAIT. After a node is spawned (its loop merely STARTS),
      fan_out BLOCKS on this before reading the worktree diff so `files_changed`
      captures the node's finished work, not the empty pre-work tree. Defaults to
      polling `RunStore.get(node_id).status` until `:completed | :failed |
      :cancelled` (or the per-node timeout). An unknown/never-registered id
      (e.g. a fake test spawn) returns immediately.
    * `:diff_fun` — 1-arity `(worktree_path) -> [binary]` override for deriving a
      node's changed files (defaults to a real `git status --porcelain` read).
    * `:budget_fun` — 1-arity `(parent) -> boolean` override for the pre-spawn
      tree-budget guard (defaults to a `Loop.get_state` + `Accounting`
      rollup check).
    * any other opt is forwarded as base spawn opts for each item.

  Each item resolves to a STRUCTURED result map (frozen contract consumed by
  `Fleet.Finalizer`):

      %{
        node_id: binary,
        worktree_ref: binary | nil,
        files_changed: [binary],
        gate: :pass | :fail | :skipped,
        stubbed: [binary],
        summary: binary,
        error: term | nil
      }

  A completed node → `gate: :pass`; an errored/timed-out node → `gate: :fail`
  with `:error` set; an item skipped because the tree budget is exhausted →
  `gate: :skipped`.

  BUDGET GUARD: before spawning each item the parent's WHOLE-TREE spend is
  checked via `Accounting.budget_exhausted?/1`. Once exhausted, spawning STOPS —
  every remaining item is marked `gate: :skipped` (dropped-for-budget) instead
  of being spawned. The check FAILS CLOSED: if the parent's spend can't be read
  (unbillable state shape, a crash in the rollup, a descendant that finished
  without leaving a spend record) it reports "exhausted" and stops spawning,
  rather than treating an unknown bill as a $0 one. The one exception is a
  parent loop that does not exist at all — there is no capped run tree to bill,
  so spawning proceeds. It never crashes the fan_out.

  DURABILITY: the run has an id (`:run_id`, minted when not supplied) and every
  item is journalled — `queued` before it is spawned, `result` as soon as it is
  terminal — by `Fleet.Journal`. Before anything is spawned the journal is
  replayed, so re-invoking `fan_out/3` with the SAME `:run_id` and item list
  finishes only the items that never completed and serves the rest from disk. A
  coordinator crash therefore costs the in-flight items, not the finished ones.
  See `resume/3`.

  Returns `{:ok, %{total: T, dropped: D, results: [...], run_id: R}}` or
  `{:error, :ultra_required}`. `results` are in SUBMISSION order.
  """
  @spec fan_out(String.t(), [term()], keyword()) ::
          {:ok,
           %{
             total: non_neg_integer(),
             dropped: non_neg_integer(),
             results: [map()],
             run_id: String.t()
           }}
          | {:error, :ultra_required | :invalid_parent_session_id}
  def fan_out(parent_session_id, items, opts \\ [])

  def fan_out(parent_session_id, items, opts)
      when is_binary(parent_session_id) and is_list(items) do
    # The ultra-only gate. Use the effort-ladder rank helper (ultra is the top
    # rung) so the check survives new tiers being added above.
    if Effort.current_at_least?(:ultra) do
      do_fan_out(parent_session_id, items, opts)
    else
      Logger.info(
        "[Fleet] fan_out refused — raise effort to ultra to run dynamic workflows " <>
          "(current: #{inspect(Effort.current())})."
      )

      {:error, :ultra_required}
    end
  end

  def fan_out(_parent, _items, _opts), do: {:error, :invalid_parent_session_id}

  @doc """
  Resume a fan-out that a coordinator crash interrupted.

  The entry point finding #7 asked for. Pass the original `run_id` and the SAME
  item list: `fan_out/3` replays the journal, returns every item that already
  reached a terminal outcome without touching it again, and executes only the
  remainder.

  This is the coordinator-side complement to `Agent.FleetResumer`, which
  re-dispatches individual orphaned NODES at boot but has no notion of a
  fan-out run, its item list, or its results.

  `Fleet.Journal.outstanding/1` reports what a given run still owed.
  """
  @spec resume(String.t(), [term()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume(parent_session_id, items, run_id, opts \\ [])
      when is_binary(run_id) and run_id != "" do
    fan_out(parent_session_id, items, Keyword.put(opts, :run_id, run_id))
  end

  defp do_fan_out(parent, items, opts) do
    cap = max_fleet_agents()
    total_cap = max_fleet_total()

    # Per-item execution context: the spawn/worktree/budget seams (each
    # overridable for tests), the isolation mode, the base opts forwarded to
    # every node, and a shared atomics "stop" flag the budget guard flips once
    # the tree budget is exhausted so remaining items skip instead of spawning.
    ctx = %{
      spawn_fun: Keyword.get(opts, :spawn_fun, &spawn_fleet_node/2),
      worktree_fun: Keyword.get(opts, :worktree_fun, &default_create_worktree/2),
      budget_fun: Keyword.get(opts, :budget_fun, &default_budget_exhausted?/1),
      # Completion-wait seam: block until a spawned node reaches a terminal state
      # so the worktree diff we read reflects its COMPLETED work (not the empty
      # pre-work tree). Overridable so unit tests need no real loops.
      await_fun: Keyword.get(opts, :await_fun, &default_await_completion/1),
      # Diff seam: repo-relative files a node changed in its worktree. Defaults to
      # a real `git status` read; injectable so tests assert a non-empty diff.
      diff_fun: Keyword.get(opts, :diff_fun, &changed_files/1),
      isolation: Keyword.get(opts, :isolation),
      # Durable run identity. Supplied by a caller resuming a crashed run;
      # minted otherwise. Everything the run learns is journalled under it.
      run_id: Keyword.get(opts, :run_id) || generate_run_id(),
      base_opts:
        Keyword.drop(opts, [
          :spawn_fun,
          :worktree_fun,
          :budget_fun,
          :await_fun,
          :diff_fun,
          :isolation,
          :run_id
        ]),
      budget_stopped: :atomics.new(1, [])
    }

    # Run-lifetime kill switch: never drain more than the total ceiling.
    {work, dropped} =
      case length(items) - total_cap do
        over when over > 0 -> {Enum.take(items, total_cap), over}
        _ -> {items, 0}
      end

    total = length(work)

    # Seed the SHARED scratchpad with a workflow header so the orchestrated
    # nodes share a common workspace and the team-visibility panel shows the
    # workflow. Best-effort — must never crash the fan_out.
    seed_workflow_scratchpad(parent, ctx.base_opts, total)

    # Start summary: everything queued, nothing spawned yet.
    emit_fleet_summary(parent, %{queued: total, cap: cap, total_spawned: 0})

    # REPLAY BEFORE TOUCHING THE HOST. Any item this run already carried to a
    # terminal outcome is served from the journal and never spawned again — a
    # fan-out node is a full agent turn that writes to the repo, so re-running
    # a completed sibling is both expensive and destructive.
    already_done = Journal.completed(ctx.run_id, work)

    if already_done != %{} do
      Logger.info(
        "[Fleet] resuming run #{ctx.run_id}: #{map_size(already_done)}/#{total} item(s) " <>
          "replayed from the journal, not re-executed"
      )
    end

    Journal.write_manifest(ctx.run_id, %{
      "run_id" => ctx.run_id,
      "parent" => parent,
      "total" => total,
      "dropped" => dropped,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    results =
      work
      |> Enum.with_index()
      |> Enum.reject(fn {_item, idx} -> Map.has_key?(already_done, idx) end)
      |> Task.async_stream(
        # The index rides along INSIDE the task so it survives every exit path.
        # `ordered: false` yields results in completion order, which made the
        # finalizer's claim table (and its conflict briefs) nondeterministic —
        # the same wave reported its nodes in a different order every run. The
        # stream still drains out of order (that is the point of the cap); the
        # RESULTS are put back in submission order below, exactly as
        # `Orchestrator.run_parallel/3` does with its `original_idx`.
        # The submission index rides along INSIDE the task, so a result can be
        # put back in the caller's order no matter which order it completed in.
        # `ordered: false` is kept deliberately: it is what lets the summary
        # gauge below tick per freed slot rather than head-of-line blocking.
        fn {item, idx} ->
          # Queued BEFORE the spawn, result as soon as it is terminal: a
          # coordinator that dies at item 9 of 10 keeps items 1..8.
          Journal.record_queued(ctx.run_id, idx, item)
          result = run_fan_out_item(parent, item, ctx)
          Journal.record_result(ctx.run_id, idx, item, result)
          {idx, result}
        end,
        max_concurrency: cap,
        ordered: false,
        # Backstop only — NOT the per-node ceiling.
        #
        # `on_timeout: :kill_task` kills the POLLER, not the node. The node's
        # own Loop has no cancel token fired for it, `RunStore.complete/2` is
        # never called, and the reaped result is `fail_result("", :node_timeout)`
        # — an empty node_id and a nil `worktree_ref`. `Fleet.Finalizer` merges a
        # node's work with `git checkout <worktree_ref> -- <files>`, so a nil ref
        # means everything that node wrote is silently never merged and its
        # branch is orphaned, all while the node is STILL RUNNING and still
        # writing to that worktree.
        #
        # So the per-node ceiling is enforced INSIDE the task instead
        # (`default_await_completion/1` → `cancel_and_confirm/1`), where the
        # node id and worktree ref are still in scope and the worker can
        # actually be cancelled. This outer deadline is set strictly longer, so
        # it only fires if that machinery itself wedges.
        timeout: fan_out_task_timeout_ms(),
        on_timeout: :kill_task
      )
      |> Stream.with_index(1)
      |> Enum.map(fn {res, completed} ->
        # One yield == one slot freed. Emit a fresh summary so the header tracks
        # the drain live; `running` is read from RunStore (source of truth).
        emit_fleet_summary(parent, %{
          queued: max(total - completed, 0),
          cap: cap,
          total_spawned: completed
        })

        res
      end)
      |> reassemble(work, already_done)

    # The run is fully accounted for in the returned results; the journal has
    # nothing left to protect.
    Journal.discard(ctx.run_id)

    {:ok, %{total: total, dropped: dropped, results: results, run_id: ctx.run_id}}
  end

  defp generate_run_id do
    "fleet-run-" <> OptimalSystemAgent.Utils.ID.generate()
  rescue
    _ -> "fleet-run-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Put the drained yields back into SUBMISSION order and give every one of them
  # a real identity.
  #
  # Two defects are closed here. `ordered: false` returned results in completion
  # order, so `Fleet.Finalizer`'s claim table and conflict briefs listed the same
  # wave's nodes differently on every run — a diagnostic a human is meant to read
  # and compare. And a task reaped by the outer backstop yields a bare
  # `{:exit, reason}` carrying no index, which produced a result with an EMPTY
  # `node_id`: the finalizer then had a failed node it could not name.
  #
  # Indexed yields are placed directly. Exits carry no index, but their set is
  # exactly the complement of the indices that did come back, so each is matched
  # to the item it must have been — recovering the node hint the reap destroyed.
  defp reassemble(yields, work, replayed) do
    # Journal-replayed items are already placed and were never submitted to the
    # stream, so they must not be mistaken for reaped tasks below.
    {placed, exits} =
      Enum.reduce(yields, {replayed, []}, fn
        {:ok, {idx, result}}, {acc, exits} -> {Map.put(acc, idx, result), exits}
        {:exit, reason}, {acc, exits} -> {acc, [reason | exits]}
      end)

    missing = Enum.reject(0..(length(work) - 1)//1, &Map.has_key?(placed, &1))
    indexed_work = Enum.with_index(work) |> Map.new(fn {item, idx} -> {idx, item} end)

    placed =
      missing
      |> Enum.zip(Enum.reverse(exits))
      |> Enum.reduce(placed, fn {idx, reason}, acc ->
        Map.put(acc, idx, exit_result(reason, Map.get(indexed_work, idx)))
      end)

    Enum.map(0..(length(work) - 1)//1, fn idx ->
      Map.get(placed, idx) || fail_result("", {:exit, :no_result})
    end)
  end

  defp exit_result(:timeout, item) do
    hint = item_hint(item)

    # Reaped by the OUTER backstop. The in-task ceiling should have fired first
    # and returned a real, identified result; reaching here means it did not and
    # the task is dead. Do not dress this up as a node we stopped — nothing was
    # cancelled and the node may well still be running.
    Logger.error(
      "[Fleet] node #{inspect(hint)} exceeded the outer backstop " <>
        "(#{fan_out_task_timeout_ms()}ms) and was reaped WITHOUT being cancelled — it may " <>
        "still be running and writing to its worktree."
    )

    fail_result(hint, {:node_timeout, :unidentified_task_reaped})
  end

  # Any other task exit (a crash we could not trap): isolate it as a fail result
  # so the remaining items still drain, but keep the item's identity.
  defp exit_result(reason, item), do: fail_result(item_hint(item), {:exit, reason})

  # The hint an item WOULD have produced, recovered from the raw item after its
  # task died. Mirrors `run_fan_out_item/3`'s normalization.
  defp item_hint(item) do
    case item do
      i when is_binary(i) -> node_hint(task: i)
      i when is_list(i) -> node_hint(i)
      i when is_map(i) -> node_hint(Map.to_list(i))
      _ -> ""
    end
  end

  # Normalize an item to per-item spawn opts, merge over the shared base opts,
  # apply the budget guard + (optional) worktree isolation, and produce the
  # structured result map (O2). `hint` is bound in the head so it stays visible
  # to the rescue/catch clauses if the node raises/throws/exits.
  defp run_fan_out_item(parent, item, ctx) do
    item_opts =
      cond do
        is_binary(item) -> [task: item]
        is_list(item) -> item
        is_map(item) -> Map.to_list(item)
        true -> []
      end

    merged = Keyword.merge(ctx.base_opts, item_opts)
    hint = node_hint(merged)
    do_run_item(parent, merged, hint, ctx)
  end

  defp do_run_item(parent, merged, hint, ctx) do
    cond do
      # Budget already tripped by an earlier item → skip without spawning.
      budget_stopped?(ctx) ->
        skipped_result(hint)

      # Pre-spawn tree-budget guard: once the whole-tree spend is exhausted,
      # flip the shared flag so every REMAINING item skips too, then skip.
      ctx.budget_fun.(parent) ->
        mark_budget_stopped(ctx)
        skipped_result(hint)

      true ->
        spawn_item(parent, merged, hint, ctx)
    end
  rescue
    # Node error isolation: a raising node becomes a fail result, its slot
    # frees, and the remaining items keep draining. Never crashes the workflow.
    e -> fail_result(hint, {:node_error, Exception.message(e)})
  catch
    :throw, val -> fail_result(hint, {:node_throw, val})
    :exit, reason -> fail_result(hint, {:exit, reason})
  end

  # Isolated spawn: create a CoW worktree, point the node's working_dir at it,
  # spawn, WAIT for the node to finish, then derive files_changed + record the
  # branch ref. Best-effort — a worktree failure logs and falls back to a
  # non-isolated spawn.
  defp spawn_item(parent, merged, hint, %{isolation: :worktree} = ctx) do
    case safe_worktree(ctx, parent, merged) do
      {:ok, %{path: path, branch: branch}} ->
        merged
        |> Keyword.put(:working_dir, path)
        |> then(&ctx.spawn_fun.(parent, &1))
        |> await_and_finalize_isolated(ctx, hint, path, branch)

      {:error, reason} ->
        Logger.warning(
          "[Fleet] worktree isolation failed for #{hint} (#{inspect(reason)}) — " <>
            "falling back to non-isolated spawn."
        )

        spawn_item(parent, merged, hint, %{ctx | isolation: nil})
    end
  end

  defp spawn_item(parent, merged, hint, ctx) do
    case ctx.spawn_fun.(parent, merged) do
      {:ok, node_id} = ok ->
        # Spawn only STARTS the node — block until it reaches a terminal state so
        # the result reflects completion. Non-isolated nodes edit the shared tree
        # directly, so there is no per-node diff to capture (files stay []).
        status = safe_await(ctx, node_id)
        spawn_result(ok, node_id, nil, [], status)

      other ->
        spawn_result(other, hint, nil, [], :unknown)
    end
  end

  # A successful isolated spawn: BLOCK on the node's completion (the make-or-break
  # fix — the spawn returned the instant the loop started, so reading the diff now
  # WITHOUT waiting would always see an empty worktree), then capture the branch
  # ref + the node's now-materialized changed files. A failed spawn keeps the
  # branch as worktree_ref with no diff.
  defp await_and_finalize_isolated({:ok, node_id} = ok, ctx, _hint, path, branch) do
    status = safe_await(ctx, node_id)
    _ = safe_attach_snapshot(node_id, branch)
    spawn_result(ok, node_id, branch, safe_diff(ctx, path), status)
  end

  defp await_and_finalize_isolated(other, _ctx, hint, _path, branch) do
    spawn_result(other, hint, branch, [], :unknown)
  end

  # Block on a node's terminal state via the (injectable) await seam; degrade to
  # `:unknown` on any failure so the workflow never crashes on the wait.
  defp safe_await(ctx, node_id) do
    ctx.await_fun.(node_id)
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # Derive changed files via the (injectable) diff seam; degrade to [].
  defp safe_diff(ctx, path) do
    ctx.diff_fun.(path)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Terminal await statuses that mean "this node did NOT finish its work".
  # `:unknown` is deliberately absent: it is what the default await returns for a
  # node that was never registered (fake test spawn / injected seam), and it
  # carries no evidence of failure.
  # Await outcomes that mean the node did NOT finish its work. `:uncancelled` is
  # the worst of them: the node blew its ceiling AND ignored the cancel, so it
  # is still running. It is a fail result like the others, but — crucially — one
  # that carries the node's real id and worktree ref, so the finalizer can still
  # see (and a human can still salvage) what it wrote.
  @incomplete_await [:failed, :cancelled, :timeout, :uncancelled]

  # Turn the spawn_fun return (plus the node's terminal await status) into a
  # structured result map. A spawn that succeeded but whose node ended in a
  # NON-completed state must NOT be reported as a pass — the finalizer merges
  # every non-errored node's worktree diff into the user's branch, so a crashed
  # node's partial tree would otherwise be committed as if it were good work.
  defp spawn_result({:ok, node_id}, _hint, worktree_ref, _files, status)
       when status in @incomplete_await,
       do: fail_result(node_id, {:node_incomplete, status}, worktree_ref)

  defp spawn_result({:ok, node_id}, _hint, worktree_ref, files, _status),
    do: success_result(node_id, worktree_ref, files)

  defp spawn_result({:error, reason}, hint, worktree_ref, _files, _status),
    do: fail_result(hint, reason, worktree_ref)

  defp spawn_result(_other, hint, worktree_ref, _files, _status),
    do: fail_result(hint, :spawn_failed, worktree_ref)

  # ── structured result builders (O2 — FROZEN CONTRACT) ──────────────────

  defp success_result(node_id, worktree_ref, files) do
    %{
      node_id: to_string(node_id),
      worktree_ref: worktree_ref,
      files_changed: files,
      gate: :pass,
      stubbed: [],
      summary: "completed",
      error: nil
    }
  end

  defp fail_result(node_id, reason, worktree_ref \\ nil) do
    %{
      node_id: to_string(node_id),
      worktree_ref: worktree_ref,
      files_changed: [],
      gate: :fail,
      stubbed: [],
      summary: "failed: #{inspect(reason)}",
      error: reason
    }
  end

  defp skipped_result(node_id) do
    %{
      node_id: to_string(node_id),
      worktree_ref: nil,
      files_changed: [],
      gate: :skipped,
      stubbed: [],
      summary: "skipped: tree budget exhausted",
      error: nil
    }
  end

  # ── budget guard helpers ───────────────────────────────────────────────

  defp budget_stopped?(%{budget_stopped: ref}), do: :atomics.get(ref, 1) == 1
  defp mark_budget_stopped(%{budget_stopped: ref}), do: :atomics.put(ref, 1, 1)

  # Fetch the parent loop's live state and ask Accounting whether the WHOLE-TREE
  # spend has reached the cap. Never crashes the fan_out.
  #
  # The three failure branches used to all return `false` ("keep spawning") with
  # the comment "degrades to false". That degrade spends real money: it is the
  # answer "I have no idea what this run has cost, carry on". The branches are
  # not equivalent, so they no longer share an answer:
  #
  #   * `{:error, _}` — there is no such loop, so there is no capped run tree to
  #     bill and nothing to enforce. Still `false`.
  #   * anything else — the loop answered, but not in a shape we can bill from,
  #     or the check itself blew up. A cap may well be set and we cannot see the
  #     spend, so we FAIL CLOSED and stop spawning.
  defp default_budget_exhausted?(parent) do
    case Loop.get_state(parent) do
      {:ok, %{session_id: sid, spend: spend}} when is_map(spend) ->
        Accounting.budget_exhausted?(%{
          session_id: sid,
          session_cost_usd: Map.get(spend, :cost_usd, 0.0),
          max_budget_usd: Map.get(spend, :max_budget_usd)
        })

      {:error, _} ->
        false

      other ->
        budget_unknown(parent, "loop state carried no spend map: #{inspect(other)}")
    end
  rescue
    e -> budget_unknown(parent, Exception.message(e))
  catch
    :exit, reason -> budget_unknown(parent, "exit #{inspect(reason)}")
  end

  defp budget_unknown(parent, why) do
    Logger.warning(
      "[Fleet] tree spend for #{parent} is UNKNOWN (#{why}) — refusing to spawn further " <>
        "nodes rather than assuming the unread spend was free"
    )

    true
  end

  # ── worktree isolation helpers ─────────────────────────────────────────

  defp safe_worktree(ctx, parent, merged) do
    ctx.worktree_fun.(parent, merged)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Default per-item worktree: a CoW worktree of the shared repo (Cwd), named
  # from the item's node hint. Returns `{:ok, %{path, branch}}` or `{:error, _}`.
  defp default_create_worktree(_parent, merged) do
    id = "fleet-wt-" <> (node_hint(merged) |> String.slice(0, 40))
    FastWorktree.create(id, [])
  end

  # Record the worktree branch/path durably on the run row (reusing RunStore's
  # `worktree_snapshot_ref`) so the finalizer can locate a node's worktree.
  defp safe_attach_snapshot(node_id, ref) when is_binary(node_id) and is_binary(ref) do
    RunStore.attach_worktree_snapshot(node_id, ref)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_attach_snapshot(_node_id, _ref), do: :ok

  # ── completion wait ────────────────────────────────────────────────────

  @default_await_poll_ms 250

  # Default per-item completion wait: poll RunStore until the node reaches a
  # terminal state (`:completed | :failed | :cancelled`), bounded by the same
  # per-node timeout the queue drain enforces. `spawn_fleet_node/2` registers the
  # run (status `:running`) BEFORE returning, so the real path always has a row to
  # poll; a never-registered id (a fake test spawn) returns `:unknown` at once so
  # unit tests don't block. Returns the terminal status atom, or `:timeout` /
  # `:unknown`.
  defp default_await_completion(node_id) when is_binary(node_id) and node_id != "" do
    deadline = System.monotonic_time(:millisecond) + node_timeout_ms()
    await_loop(node_id, deadline)
  end

  defp default_await_completion(_), do: :unknown

  defp await_loop(node_id, deadline) do
    case RunStore.get(node_id) do
      %{status: status} when status in [:completed, :failed, :cancelled] ->
        status

      nil ->
        # Never registered — nothing to wait on (fake test spawn / stale id).
        :unknown

      _running ->
        if System.monotonic_time(:millisecond) >= deadline do
          cancel_and_confirm(node_id)
        else
          Process.sleep(await_poll_ms())
          await_loop(node_id, deadline)
        end
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  # The node ran past its ceiling. Cancel the WORKER and wait for it to
  # acknowledge by reaching a terminal state, instead of killing the poller and
  # leaving the node running behind a fabricated "failed" result.
  #
  # Returns `:timeout` once the node has actually stopped, or `:uncancelled` if
  # it never acknowledged — a distinct outcome precisely so the result does not
  # claim a node was stopped when it was not.
  defp cancel_and_confirm(node_id) do
    Logger.warning(
      "[Fleet] node #{node_id} exceeded #{node_timeout_ms()}ms — cancelling it and waiting " <>
        "for acknowledgement"
    )

    _ = safe_cancel(node_id)
    confirm_loop(node_id, System.monotonic_time(:millisecond) + cancel_ack_ms())
  end

  defp confirm_loop(node_id, deadline) do
    case RunStore.get(node_id) do
      %{status: status} when status in [:completed, :failed, :cancelled] ->
        Logger.info("[Fleet] node #{node_id} acknowledged cancellation (:#{status})")
        :timeout

      nil ->
        :timeout

      _running ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.error(
            "[Fleet] node #{node_id} did NOT acknowledge cancellation within " <>
              "#{cancel_ack_ms()}ms — it is still running and still writing to its worktree. " <>
              "Reporting :uncancelled rather than claiming it was stopped."
          )

          :uncancelled
        else
          Process.sleep(await_poll_ms())
          confirm_loop(node_id, deadline)
        end
    end
  end

  defp safe_cancel(node_id) do
    Loop.cancel(node_id)
  rescue
    e -> Logger.warning("[Fleet] cancel of #{node_id} failed: #{Exception.message(e)}")
  catch
    _, reason -> Logger.warning("[Fleet] cancel of #{node_id} exited: #{inspect(reason)}")
  end

  defp await_poll_ms do
    Application.get_env(:optimal_system_agent, :fleet_await_poll_ms, @default_await_poll_ms)
  end

  @doc """
  How long a cancelled node is given to acknowledge (reach a terminal state)
  before the drain gives up on it and reports `:uncancelled`.
  """
  @spec cancel_ack_ms() :: pos_integer()
  def cancel_ack_ms do
    configured =
      Application.get_env(:optimal_system_agent, :fleet_cancel_ack_ms, @default_cancel_ack_ms)

    # Never give a node longer to acknowledge than it was given to run. A caller
    # that sets a tight ceiling (tests, short jobs) means it, and a fixed 30s
    # grace on an 80ms ceiling would make the outer backstop 375x the ceiling.
    min(configured, node_timeout_ms())
  end

  @doc """
  Outer `Task.async_stream` backstop, strictly longer than the in-task ceiling
  (`node_timeout_ms/0` + the cancel-acknowledgement window + slack for worktree
  creation). The in-task path must win the race — it is the only one that can
  identify and cancel the node.
  """
  @spec fan_out_task_timeout_ms() :: pos_integer()
  def fan_out_task_timeout_ms do
    ceiling = node_timeout_ms()
    ceiling + cancel_ack_ms() + min(@task_backstop_slack_ms, ceiling)
  end

  # Repo-relative paths a node modified in its worktree (best-effort `git status
  # --porcelain`). `[]` when the tree is clean, git is unavailable, or the path
  # doesn't exist (e.g. a fake worktree ref in unit tests).
  defp changed_files(path) when is_binary(path) do
    # Guard on existence: `System.cmd` cd-ing into a vanished/fake dir prints a
    # noisy `spawn: Could not cd` to stderr (and there's nothing to diff anyway).
    if not File.dir?(path) do
      []
    else
      changed_files_git(path)
    end
  end

  defp changed_files(_), do: []

  defp changed_files_git(path) do
    case OptimalSystemAgent.Git.cmd(["status", "--porcelain", "-z"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {out, 0} -> parse_porcelain_z(out)
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Parse `git status --porcelain -z` output into a de-duplicated list of
  # repo-relative paths.
  #
  # The `-z` format is NUL-separated and, critically, a rename/copy entry
  # (`R`/`C` in the XY status) spans TWO NUL-separated fields: the destination
  # path (carrying the `XY ` status prefix) followed by a BARE origin path with
  # NO status prefix. A naive `split(NUL) |> map(strip 3 chars)` corrupts that
  # origin field (it slices off its first 3 bytes) and silently produces a wrong
  # path — which then breaks the finalizer's `git checkout <ref> -- <path>` merge.
  #
  # This parser walks entries sequentially and, on a rename/copy, consumes the
  # following bare field as the origin path verbatim. Both the destination and
  # origin paths are returned (both are genuinely changed). Public + `@doc false`
  # so the NUL/rename parsing is unit-testable without invoking real git.
  @doc false
  @spec parse_porcelain_z(binary()) :: [binary()]
  def parse_porcelain_z(out) when is_binary(out) do
    out
    |> String.split(<<0>>, trim: true)
    |> parse_porcelain_entries([])
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_porcelain_z(_), do: []

  # Sequential walk: each entry is `XY <path>`; a rename/copy also consumes the
  # NEXT (bare, unprefixed) field as the origin path.
  defp parse_porcelain_entries([], acc), do: Enum.reverse(acc)

  defp parse_porcelain_entries([entry | rest], acc) when byte_size(entry) > 3 do
    xy = binary_part(entry, 0, 2)
    path = entry |> binary_part(3, byte_size(entry) - 3) |> String.trim()

    if rename_or_copy?(xy) do
      case rest do
        [orig | rest2] -> parse_porcelain_entries(rest2, [String.trim(orig), path | acc])
        [] -> parse_porcelain_entries([], [path | acc])
      end
    else
      parse_porcelain_entries(rest, [path | acc])
    end
  end

  # Malformed/short field: skip it (do not slice a sub-3-byte string).
  defp parse_porcelain_entries([_short | rest], acc), do: parse_porcelain_entries(rest, acc)

  defp rename_or_copy?(<<x, y>>), do: x in [?R, ?C] or y in [?R, ?C]
  defp rename_or_copy?(_), do: false

  defp node_hint(opts) do
    (Keyword.get(opts, :node_id) || Keyword.get(opts, :task) || "") |> to_string()
  end

  defp do_spawn(parent_session_id, opts) do
    agent_type = Keyword.get(opts, :agent_type, @default_agent_type) |> to_string()
    task = Keyword.get(opts, :task, "") |> to_string()
    node_id = Keyword.get(opts, :node_id) || generate_node_id(parent_session_id)
    user_id = Keyword.get(opts, :user_id, "fleet")

    working_dir =
      Keyword.get(opts, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()

    # A node given a `:working_dir` other than the cwd cascade root runs against
    # settings resolved from the CWD, not from that root. Say so if the root
    # carries a settings file — see `SettingsCoverage` for why this is a
    # diagnostic rather than a `Watcher.register_root/1` call.
    SettingsCoverage.check(working_dir, "fleet node #{node_id}")

    {system_prompt, allowed_tools} =
      resolve_agent_type(agent_type, Keyword.get(opts, :system_prompt))

    depth = tree_depth(parent_session_id) + 1

    # Register the node in the run tree FIRST so it appears in RunStore.list even
    # if the loop start races — SessionManager does NOT do this.
    RunStore.start_run(%{
      agent_id: node_id,
      parent_session_id: parent_session_id,
      role: agent_type,
      task: task
    })

    emit_fleet_event(parent_session_id, %{
      event: "fleet_node_started",
      node_id: node_id,
      agent_type: agent_type,
      task: String.slice(task, 0, 200),
      flavor: "full",
      depth: depth
    })

    loop_opts =
      [
        user_id: user_id,
        # NOTE: no permission_tier, no channel: :internal — Loop.init defaults to
        # :full (full tools/MCP/memory/permissions). This is what makes a fleet
        # node full-power rather than a restricted delegate worker.
        working_dir: working_dir,
        parent_session_id: parent_session_id,
        system_prompt_override: system_prompt,
        allowed_tools: allowed_tools
      ]

    case SessionManager.ensure_loop(node_id, loop_opts) do
      :ok ->
        # Drive the node and watch it to completion. The watcher subscribes to the
        # node's PubSub topic for tool progress and monitors the driver task so it
        # can emit fleet_node_progress / fleet_node_completed.
        start_watcher(parent_session_id, node_id, agent_type, task)
        {:ok, node_id}

      {:error, reason} = err ->
        Logger.error("[Fleet] ensure_loop failed for #{node_id}: #{inspect(reason)}")

        RunStore.complete(node_id, %{status: :failed, summary: "spawn failed: #{inspect(reason)}"})

        emit_fleet_event(parent_session_id, %{
          event: "fleet_node_completed",
          node_id: node_id,
          summary: "spawn failed: #{inspect(reason)}",
          status: "failed"
        })

        err
    end
  end

  @doc """
  Resolve an agent-type to `{system_prompt, allowed_tools}`.

  An explicit `system_prompt` override wins. Otherwise the existing
  `Agents.Registry` (AGENT.md definitions) is consulted, then the built-in
  `@fleet_agent_types` fallback. `allowed_tools == nil` means the full toolset.
  """
  @spec resolve_agent_type(String.t(), String.t() | nil) :: {String.t() | nil, [String.t()] | nil}
  def resolve_agent_type(agent_type, explicit_prompt \\ nil)

  def resolve_agent_type(_agent_type, prompt) when is_binary(prompt) and prompt != "" do
    {prompt, nil}
  end

  def resolve_agent_type(agent_type, _explicit_prompt) do
    case safe_registry_get(agent_type) do
      %{} = def ->
        {blank_to_nil(def[:system_prompt]), def[:tools_allowed]}

      _ ->
        case Map.get(@fleet_agent_types, agent_type) do
          %{system_prompt: prompt, tools: tools} -> {prompt, tools}
          _ -> {nil, nil}
        end
    end
  end

  @doc """
  Number of runs currently in the `:running` state (the fleet size).

  Scoped to runs this process may own: `~/.osa/agent-runs` is machine-global and
  is rehydrated at every boot, so a plain `RunStore.list/1` in a second `osa`
  invocation counts the FIRST invocation's live subagents against this process's
  fleet caps. Only runs whose ownership lease is actively held elsewhere are
  excluded — lease-less legacy rows still count, so single-process behaviour is
  unchanged.
  """
  @spec running_count() :: non_neg_integer()
  def running_count do
    RunStore.all_running_local() |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Configured fleet-wide total-agent cap (`:max_fleet_agents`)."
  @spec max_fleet_agents() :: pos_integer()
  def max_fleet_agents do
    Application.get_env(:optimal_system_agent, :max_fleet_agents, @default_max_fleet_agents)
  end

  @doc "Run-lifetime kill switch — max nodes a single fan_out drains (`:max_fleet_total`)."
  @spec max_fleet_total() :: pos_integer()
  def max_fleet_total do
    Application.get_env(:optimal_system_agent, :max_fleet_total, @default_max_fleet_total)
  end

  @doc "Per-node fan_out timeout in ms (`:node_timeout_ms`, default 5 min)."
  @spec node_timeout_ms() :: pos_integer()
  def node_timeout_ms do
    Application.get_env(:optimal_system_agent, :node_timeout_ms, @default_node_timeout_ms)
  end

  # ── internals ────────────────────────────────────────────────────────

  # Watch the node: subscribe to its session topic, drive its first turn via
  # process_message_async, forward progress, and emit completion when the driver
  # task ends. Runs in its own supervised task so it never blocks the caller.
  defp start_watcher(parent_id, node_id, agent_type, task) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{node_id}")

      driver_ref =
        case SessionManager.process_message_async(node_id, task) do
          {:ok, pid} -> Process.monitor(pid)
          _ -> nil
        end

      watch_loop(parent_id, node_id, agent_type, 0, driver_ref)
    end)
  end

  defp watch_loop(parent_id, node_id, agent_type, tool_count, driver_ref) do
    receive do
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase, args: args}}
      when phase in ["start", :start] ->
        action = format_action(tool_name, args)
        RunStore.progress(node_id, action, tool_count)
        emit_progress(parent_id, node_id, action, tool_count)
        watch_loop(parent_id, node_id, agent_type, tool_count, driver_ref)

      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase}}
      when phase in ["end", :end] ->
        new_count = tool_count + 1
        action = to_string(tool_name)
        RunStore.progress(node_id, action, new_count)
        emit_progress(parent_id, node_id, action, new_count)
        watch_loop(parent_id, node_id, agent_type, new_count, driver_ref)

      {:DOWN, ref, :process, _pid, reason} when ref == driver_ref ->
        finish(parent_id, node_id, reason)

      _ ->
        watch_loop(parent_id, node_id, agent_type, tool_count, driver_ref)
    after
      # Idle leak-guard: stop watching after prolonged silence (mirrors the
      # orchestrator forwarder). Completion normally arrives via :DOWN first.
      Application.get_env(:optimal_system_agent, :forwarder_idle_timeout_ms, 1_800_000) ->
        finish(parent_id, node_id, :idle_timeout)
    end
  end

  defp finish(parent_id, node_id, reason) do
    status = if reason == :normal, do: :completed, else: :failed
    # MUST read tokens before stop_node/1 below — node_tokens/1 asks the live
    # Loop for its state, and a stopped loop reports 0.
    tokens = node_tokens(node_id)
    summary = completion_summary(node_id, status, reason)

    RunStore.complete(node_id, %{
      status: status,
      summary: summary,
      tokens_used: tokens
    })

    emit_fleet_event(parent_id, %{
      event: "fleet_node_completed",
      node_id: node_id,
      summary: summary,
      status: to_string(status)
    })

    # Retire the node's Loop GenServer. Without this every delegation leaked a
    # live loop holding a FULL transcript for the lifetime of the daemon — the
    # single largest per-delegation leak in the fleet path. Safe here because
    # everything downstream of completion (`default_await_completion/1`, the
    # worktree diff, the fan_out result map) reads RunStore and the filesystem,
    # never the loop; and RunStore.complete/2 above has already recorded the
    # terminal state a waiter polls for. Reached on every terminal path:
    # success, failure, driver crash, and the watcher's idle timeout.
    stop_node(node_id)
  end

  @doc """
  Stop a fleet node's Loop GenServer and free its transcript.

  Idempotent and best-effort: a node whose loop already exited (crash, prior
  stop) is a no-op, and no failure here is allowed to disturb the parent's
  completion accounting.
  """
  @spec stop_node(String.t()) :: :ok
  def stop_node(node_id) when is_binary(node_id) do
    case SessionManager.stop_session(node_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.debug("[Fleet] stop_node #{node_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def stop_node(_), do: :ok

  @doc """
  Stop every still-running fleet node spawned under `parent_session_id`.

  This is the parent-shutdown half of the leak: `finish/3` retires a node that
  reaches a terminal state, but a parent that is stopped mid-delegation would
  otherwise strand its children as live loops with nobody left to finish them.
  Called from `Runtime.SessionManager.stop_session/1`.

  Only direct children are walked; each child's own `stop_session` recurses, so
  a deep tree unwinds level by level. Returns the number of nodes stopped.
  """
  @spec stop_children(String.t()) :: non_neg_integer()
  def stop_children(parent_session_id) when is_binary(parent_session_id) do
    # `all_running_local/0`, not `all_running/0`: cancelling a child that another
    # live `osa` process owns would kill work this process never started.
    RunStore.all_running_local()
    |> Enum.filter(&(Map.get(&1, :parent_session_id) == parent_session_id))
    |> Enum.map(& &1.agent_id)
    |> Enum.reject(&(&1 == parent_session_id))
    |> Enum.map(fn node_id ->
      RunStore.complete(node_id, %{status: :cancelled, summary: "parent session stopped"})
      stop_node(node_id)
      node_id
    end)
    |> length()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  def stop_children(_), do: 0

  defp emit_progress(parent_id, node_id, action, tool_count) do
    emit_fleet_event(parent_id, %{
      event: "fleet_node_progress",
      node_id: node_id,
      current_action: action,
      tool_uses: tool_count,
      tokens_used: node_tokens(node_id),
      recent_actions: recent_actions(node_id)
    })
  end

  # Emit on the Bus as a :system_event carrying the parent/root session_id — the
  # TuiForwarder allowlist (fleet_node_*) bridges it to osa:session:<parent>.
  defp emit_fleet_event(parent_session_id, payload) do
    Bus.emit(:system_event, Map.put(payload, :session_id, parent_session_id))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Emit a live `fleet_summary` counter for the roster header. `running` is read
  # from RunStore (source of truth for :running nodes); `warn: true` once
  # running+queued crosses the "large fleet" advisory threshold (25).
  defp emit_fleet_summary(parent, %{queued: queued, cap: cap, total_spawned: spawned}) do
    running = running_count()

    emit_fleet_event(parent, %{
      event: "fleet_summary",
      running: running,
      queued: queued,
      cap: cap,
      total_spawned: spawned,
      warn: running + queued >= @large_fleet_threshold
    })
  end

  # Seed the shared scratchpad with a workflow header entry (task + item count)
  # at the start of a fan_out so every orchestrated node shares a common
  # workspace and the team-visibility panel surfaces the workflow. The entry is
  # written to the coordinator's SESSION ROOT — the same directory every spawned
  # node resolves via `Scratchpad.session_root/1` — and a `scratchpad_activity`
  # event is emitted so the TUI panel lights up. Entirely best-effort: any
  # failure (bad path, disabled scratchpad, emit crash) is swallowed so the
  # fan_out proceeds regardless.
  defp seed_workflow_scratchpad(parent, base_opts, item_count) do
    id = Scratchpad.session_root(parent)
    task = base_opts |> Keyword.get(:task, "") |> to_string() |> String.trim()

    header =
      "# Dynamic workflow\n\n" <>
        "Coordinator: #{parent}\n" <>
        "Items: #{item_count}\n" <>
        "Started: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n\n" <>
        "Task: #{if task == "", do: "(unspecified)", else: task}\n\n" <>
        "Nodes: publish findings/partial results here so siblings and the " <>
        "coordinator can read them.\n"

    case Scratchpad.write(id, "workflow.md", header) do
      {:ok, _path} ->
        Bus.emit(:system_event, %{
          event: :scratchpad_activity,
          session_id: id,
          agent: "fleet-workflow",
          entry: "workflow.md",
          action: :write,
          bytes: byte_size(header)
        })

        :ok

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp node_tokens(node_id) do
    case Loop.get_state(node_id) do
      {:ok, %{tokens_used: t}} when is_integer(t) and t >= 0 -> t
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp recent_actions(node_id) do
    case RunStore.get(node_id) do
      %{recent_actions: actions} when is_list(actions) -> Enum.take(actions, 5)
      _ -> []
    end
  end

  defp completion_summary(node_id, :completed, _reason) do
    case RunStore.get(node_id) do
      %{recent_actions: [last | _]} when is_binary(last) -> "Completed — last: #{last}"
      _ -> "Completed"
    end
  end

  defp completion_summary(_node_id, :failed, reason), do: "Failed: #{inspect(reason)}"

  defp format_action(tool_name, args) when is_binary(args) do
    hint = String.slice(args, 0, 60)

    if hint == "" or hint == "{}" do
      to_string(tool_name)
    else
      "#{tool_name}: #{hint}"
    end
  end

  defp format_action(tool_name, _), do: to_string(tool_name)

  # Tree depth = number of ancestors from this session up to the root via the
  # RunStore parent_session_id chain. Bounded so a corrupt cycle can't loop.
  defp tree_depth(session_id, seen \\ MapSet.new(), acc \\ 0)

  defp tree_depth(_session_id, _seen, acc) when acc > 64, do: acc

  defp tree_depth(session_id, seen, acc) do
    cond do
      is_nil(session_id) or MapSet.member?(seen, session_id) ->
        acc

      true ->
        case RunStore.get(session_id) do
          %{parent_session_id: parent} when is_binary(parent) and parent != "" ->
            tree_depth(parent, MapSet.put(seen, session_id), acc + 1)

          _ ->
            acc
        end
    end
  end

  defp safe_registry_get(name) do
    AgentRegistry.get(name)
  rescue
    _ -> nil
  end

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      _ -> s
    end
  end

  defp blank_to_nil(_), do: nil

  defp generate_node_id(parent_session_id) do
    "fleet:#{parent_session_id}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
