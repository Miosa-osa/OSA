defmodule OptimalSystemAgent.Tools.Builtins.Fleet.Handler do
  @moduledoc """
  Validation, permission checking, and execution logic for `fleet`.

  Split mirrors the `Delegate.Handler` pattern:
    * `validate/2`           — type-check input shape (cheap, no I/O)
    * `check_permissions/2`  — deny obviously invalid requests
    * `execute/2`            — dispatch to `Agent.Fleet`

  The `fleet` tool exposes the FULL-POWER peer-spawn path
  (`Agent.Fleet.spawn_fleet_node/2`) and the ULTRA-GATED dynamic-workflow
  fan-out (`Agent.Fleet.fan_out/3`) to the model. This is DELIBERATELY NOT
  `delegate` (the restricted `Orchestrator.run_subagent` path): a fleet node is
  a full-power OSA loop booted as a background peer.

  Two actions:
    * `"spawn"`    — spawn ONE full-power peer (any effort). The "fire off
      5-10 peers" path.
    * `"workflow"` — run a dynamic workflow over a list of `items`. ULTRA-GATED:
      `fan_out/3` returns `{:error, :ultra_required}` below the ultra effort
      tier, surfaced here as a clear "raise effort to ultra" message.

  ## Test seam
  The per-item spawn function is resolved from the `:fleet_spawn_fun` app-env
  (default `&Agent.Fleet.spawn_fleet_node/2`) so tests can exercise the handler
  without booting real agent loops. The ultra-gate itself always lives in
  `fan_out/3`, so injecting a fake spawn fn never bypasses it.
  """

  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.Fleet.Finalizer
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Tools.UseContext

  @valid_actions ~w(spawn workflow)

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t() | nil) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    cond do
      action not in @valid_actions ->
        {:error, "Unknown action '#{action}'. Valid actions: #{Enum.join(@valid_actions, ", ")}",
         -32_602}

      action == "spawn" and not is_binary(Map.get(input, "task")) ->
        {:error, "action 'spawn' requires a string 'task'", -32_602}

      action == "workflow" and not is_list(Map.get(input, "items")) ->
        {:error, "action 'workflow' requires an array of string 'items'", -32_602}

      action == "workflow" and Map.get(input, "items") == [] ->
        {:error, "action 'workflow' requires a non-empty array of 'items'", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t() | nil) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"action" => "spawn", "task" => task} = input, ctx) do
    cond do
      String.trim(to_string(task)) == "" ->
        {:deny, "Access denied: task description must not be blank"}

      # Hard fork-bomb ceiling (defense-in-depth) — mirrors Delegate.Handler.
      # ToolFilter strips spawning tools at max depth, but a call that survives
      # filtering is denied here too so the depth ceiling is actually enforced.
      delegation_depth(ctx) >= ToolFilter.max_delegation_depth() ->
        {:deny, "Access denied: delegation depth limit reached"}

      true ->
        {:allow, input}
    end
  end

  def check_permissions(%{"action" => "workflow"} = input, ctx) do
    items = Map.get(input, "items", [])

    cond do
      not Enum.all?(items, &is_binary/1) ->
        {:deny, "Access denied: every workflow item must be a string"}

      Enum.all?(items, fn i -> String.trim(i) == "" end) ->
        {:deny, "Access denied: workflow items must not all be blank"}

      delegation_depth(ctx) >= ToolFilter.max_delegation_depth() ->
        {:deny, "Access denied: delegation depth limit reached"}

      true ->
        {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "spawn", "task" => task} = args, ctx) do
    parent = resolve_parent_id(args, ctx)
    agent_type = agent_type(args)
    opts = spawn_opts(task, args)

    case spawn_fun().(parent, opts) do
      {:ok, node_id} ->
        {:ok,
         "Spawned full-power fleet node #{node_id} (agent_type: #{agent_type}). " <>
           "It runs in the background as a peer OSA agent and reports on the fleet " <>
           "roster (fleet_node_started → progress → completed). Fire off more with " <>
           "additional fleet spawn calls."}

      {:error, {:fleet_cap_reached, running, cap}} ->
        {:ok,
         "Fleet at capacity (#{running}/#{cap}) — cannot spawn another node right now. " <>
           "Wait for running nodes to finish, or raise :max_fleet_agents."}

      {:error, reason} ->
        {:ok, "Fleet spawn failed: #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => "workflow"} = args, ctx) do
    parent = resolve_parent_id(args, ctx)
    items = Map.get(args, "items", [])
    isolate? = Map.get(args, "isolation", false) == true
    base_opts = [spawn_fun: spawn_fun()] ++ worktree_seam() ++ workflow_opts(args, isolate?)

    case Fleet.fan_out(parent, items, base_opts) do
      {:ok, %{total: total, dropped: dropped, results: results}} ->
        {:ok,
         format_workflow(total, dropped, results) <>
           maybe_finalize(parent, args, isolate?, results)}

      {:error, :ultra_required} ->
        {:ok,
         "Dynamic workflows are ultra-gated. Raise effort to ultra to run dynamic " <>
           "workflows — the current effort tier is too low. (Single peers via " <>
           "action 'spawn' work at any effort.)"}

      {:error, reason} ->
        {:ok, "Fleet workflow failed: #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => action}, _ctx) do
    {:ok,
     "Action '#{action}' is missing required parameters. " <>
       "Valid actions: #{Enum.join(@valid_actions, ", ")}"}
  end

  # ── Private ────────────────────────────────────────────────────────────

  # Resolvable test seam: default full-power spawn, overridable so the handler
  # can be exercised without booting real loops. The ultra-gate lives in
  # fan_out/3, so injecting a fake here never bypasses gating.
  defp spawn_fun do
    Application.get_env(:optimal_system_agent, :fleet_spawn_fun, &Fleet.spawn_fleet_node/2)
  end

  defp agent_type(args) do
    case Map.get(args, "agent_type") do
      t when is_binary(t) ->
        case String.trim(t) do
          "" -> "general-purpose"
          trimmed -> trimmed
        end

      _ ->
        "general-purpose"
    end
  end

  defp spawn_opts(task, args) do
    [task: to_string(task), agent_type: agent_type(args)]
    |> maybe_put(:working_dir, Map.get(args, "working_dir"))
  end

  # Base opts forwarded to every workflow item. Per-item task comes from `items`;
  # `task` here is the umbrella instruction used for the scratchpad header.
  # `isolate?` opts each item into its own CoW worktree (O1) so the finalizer has
  # disjoint diffs to merge.
  defp workflow_opts(args, isolate?) do
    [agent_type: agent_type(args)]
    |> maybe_put(:task, Map.get(args, "task"))
    |> maybe_put(:working_dir, Map.get(args, "working_dir"))
    |> maybe_put_isolation(isolate?)
  end

  defp maybe_put_isolation(opts, true), do: Keyword.put(opts, :isolation, :worktree)
  defp maybe_put_isolation(opts, _false), do: opts

  # Optional worktree-creation seam so the handler's isolation path is testable
  # without booting real git worktrees (mirrors the :fleet_spawn_fun seam). Absent
  # by default → fan_out uses the real FastWorktree creator.
  defp worktree_seam do
    case Application.get_env(:optimal_system_agent, :fleet_worktree_fun) do
      fun when is_function(fun, 2) -> [worktree_fun: fun]
      _ -> []
    end
  end

  # Injectable finalizer (default `Fleet.Finalizer.finalize/3`) so the tool's
  # finalize wiring is unit-testable without real git.
  defp finalize_fun do
    Application.get_env(:optimal_system_agent, :fleet_finalize_fun, &Finalizer.finalize/3)
  end

  # O3 wiring: after the wave, iff `finalize` was requested AND isolation actually
  # ran, merge the disjoint worktree diffs → run the authoritative `gate` → commit
  # `commit_message` when green, and fold the finalizer's result into the message.
  # `finalize` without `isolation` has nothing to merge, so it is skipped (noted).
  defp maybe_finalize(parent, args, isolate?, results) do
    finalize? = Map.get(args, "finalize", false) == true

    cond do
      not finalize? ->
        ""

      not isolate? ->
        "\n\nFinalize skipped: `finalize` requires `isolation: true` — there are " <>
          "no isolated worktree diffs to merge."

      true ->
        fin =
          finalize_fun().(parent, results,
            gate_cmds: gate_cmds(args),
            commit: commit_message(args)
          )

        format_finalize(fin)
    end
  end

  defp gate_cmds(args) do
    case Map.get(args, "gate") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp commit_message(args) do
    case Map.get(args, "commit_message") do
      m when is_binary(m) ->
        case String.trim(m) do
          "" -> nil
          _ -> m
        end

      _ ->
        nil
    end
  end

  defp format_finalize(%{} = fin) do
    merged = fin |> Map.get(:merged, []) |> length()
    conflicts = Map.get(fin, :conflicts, [])
    gate = Map.get(fin, :gate)
    committed = Map.get(fin, :committed, false)

    conflict_note =
      if conflicts == [],
        do: "no conflicts",
        else: "#{length(conflicts)} conflict(s): #{Enum.join(conflicts, ", ")}"

    "\n\nFinalize: merged #{merged} file(s), #{conflict_note}, gate #{gate}, " <>
      "committed #{committed}."
  end

  defp format_finalize(_), do: "\n\nFinalize: no result."

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_workflow(total, dropped, results) do
    # Results are the O2 structured node maps (%{gate: :pass | :fail | :skipped, ...}),
    # not {:ok, _}/{:error, _} tuples — count by the gate field.
    ok = Enum.count(results, &(is_map(&1) and &1[:gate] == :pass))
    failed = Enum.count(results, &(is_map(&1) and &1[:gate] == :fail))
    skipped = Enum.count(results, &(is_map(&1) and &1[:gate] == :skipped))

    skip_note = if skipped > 0, do: ", #{skipped} skipped (budget)", else: ""

    drop_note =
      if dropped > 0,
        do: " (#{dropped} item#{if dropped == 1, do: "", else: "s"} dropped — run-lifetime cap)",
        else: ""

    "Dynamic workflow drained #{total} item#{if total == 1, do: "", else: "s"}#{drop_note}: " <>
      "#{ok} spawned OK, #{failed} failed#{skip_note}. Full-power peers run in the background and " <>
      "report on the fleet roster; shared results land in the workflow scratchpad."
  end

  defp resolve_parent_id(_args, %UseContext{session_id: sid}) when is_binary(sid), do: sid

  defp resolve_parent_id(args, ctx) do
    (ctx && is_map(ctx) && Map.get(ctx, :session_id)) ||
      Map.get(args, "__session_id__") || "unknown"
  end

  defp delegation_depth(ctx) when is_map(ctx) do
    case Map.get(ctx, :delegation_depth, 0) do
      d when is_integer(d) and d >= 0 -> d
      _ -> 0
    end
  end

  defp delegation_depth(_), do: 0
end
