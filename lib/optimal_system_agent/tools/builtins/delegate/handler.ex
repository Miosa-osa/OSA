defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Handler do
  @moduledoc """
  Validation, permission checking, and execution logic for `delegate`.

  Split mirrors the FileRead.Handler pattern:
    * `validate/2`           — type-check input shape (cheap, no I/O)
    * `check_permissions/2`  — deny obviously invalid delegation requests
    * `execute/2`            — dispatch to Orchestrator

  The tier floor (:utility → :specialist promotion) lives here because it is
  a business rule, not a display concern.
  """

  alias OptimalSystemAgent.Tools.Builtins.Delegate.Constants
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Agent.DelegationPolicy
  alias OptimalSystemAgent.Agent.Loop.ToolFilter

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"task" => task} = input, _ctx) when is_binary(task), do: {:ok, input}

  def validate(%{"task" => _}, _ctx),
    do: {:error, "task must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: task", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"task" => task} = input, ctx) do
    cond do
      String.trim(task) == "" ->
        {:deny, "Access denied: task description must not be blank"}

      # Hard fork-bomb ceiling (defense-in-depth). ToolFilter strips the delegate
      # tool once depth >= max, but filtering is heuristic/lossy — a call that
      # survives filtering (FastPath, budget trimming, hand-crafted) would still
      # execute and spawn another level. Deny every spawn path (single + fan-out)
      # here so the depth ceiling is actually enforced, not just advertised.
      delegation_depth(ctx) >= ToolFilter.max_delegation_depth() ->
        {:deny, "Access denied: delegation depth limit reached"}

      true ->
        check_delegation_policy(input, ctx)
    end
  end

  # Tri-mode delegation policy gate (primitive #34). Enforced here as
  # defense-in-depth: ToolFilter already strips the tool from the LLM's list
  # when delegation is not permitted, but a still-listed / hand-crafted call is
  # denied here too. `:proactive` allows, `:disabled` denies, `:explicit_only`
  # allows only when the user asked to delegate this turn.
  defp check_delegation_policy(input, ctx) do
    policy = DelegationPolicy.resolve(%{delegation_policy: ctx_policy(ctx)})
    messages = ctx_messages(ctx)

    cond do
      policy == :disabled ->
        {:deny,
         "Access denied: delegation is disabled for this session (delegation policy: disabled)"}

      policy == :explicit_only and not DelegationPolicy.user_requested?(messages) ->
        {:deny,
         "Access denied: delegation policy is explicit-only — the user has not requested delegation this turn"}

      true ->
        {:allow, input}
    end
  end

  defp ctx_policy(%UseContext{delegation_policy: p}), do: p
  defp ctx_policy(ctx) when is_map(ctx), do: Map.get(ctx, :delegation_policy)
  defp ctx_policy(_), do: nil

  defp ctx_messages(%UseContext{messages: m}) when is_list(m), do: m
  defp ctx_messages(ctx) when is_map(ctx), do: Map.get(ctx, :messages) || []
  defp ctx_messages(_), do: []

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"task" => task} = args, ctx) do
    parent_id = resolve_parent_id(args, ctx)
    parent_depth = delegation_depth(ctx)

    case normalize_tasks(Map.get(args, "tasks")) do
      [] ->
        # ── Single-task path (unchanged behaviour) ──────────────────────
        role = Map.get(args, "role") || Map.get(args, "subagent_type")
        config = build_config(task, role, args, parent_id, parent_depth)

        config =
          if Map.get(args, "fork") == true do
            Map.put(config, :fork_messages, fetch_parent_messages(parent_id))
          else
            config
          end

        if background?(args, config) do
          dispatch_background(parent_id, config)
        else
          dispatch_foreground(config)
        end

      tasks ->
        # ── Fan-out path — first-class parallel wave via run_parallel ────
        dispatch_fanout(task, tasks, args, parent_id, parent_depth)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  # Build a subagent config from tool args, an explicit child task string, and
  # a resolved role. Shared by the single-task and fan-out paths so tier floor,
  # agent-definition lookup, isolation, and depth propagation stay identical.
  defp build_config(child_task, role, args, parent_id, parent_depth, name \\ nil) do
    tier_str = Map.get(args, "tier")
    agent_def = if role, do: AgentRegistry.get(role), else: nil

    raw_tier =
      cond do
        tier_str -> parse_tier(tier_str)
        agent_def -> agent_def[:tier] || Constants.min_subagent_tier()
        true -> Constants.min_subagent_tier()
      end

    # Enforce tier floor: utility models can't do tool calling reliably.
    tier = if raw_tier == :utility, do: Constants.min_subagent_tier(), else: raw_tier

    isolation =
      case Map.get(args, "isolation") || (agent_def && agent_def[:isolation]) do
        "worktree" -> :worktree
        :worktree -> :worktree
        _ -> nil
      end

    %{
      task: child_task,
      parent_session_id: parent_id,
      role: role || "agent",
      # Stable UI handle → @name id + "Teammate @name finished" line. Per-task
      # name (fan-out) wins over a top-level "name" arg.
      name: name || Map.get(args, "name"),
      tier: tier,
      model: Map.get(args, "model") || (agent_def && agent_def[:model]),
      provider: Map.get(args, "provider") || (agent_def && agent_def[:provider]),
      permission_tier:
        parse_permission_tier(
          Map.get(args, "permissionMode") ||
            Map.get(args, "permission_mode") ||
            (agent_def && agent_def[:permission_tier])
        ),
      system_prompt: agent_def && agent_def[:system_prompt],
      tools_allowed: agent_def && agent_def[:tools_allowed],
      tools_blocked: (agent_def && agent_def[:tools_blocked]) || [],
      max_iterations:
        parse_max_iterations(
          Map.get(args, "maxTurns") ||
            Map.get(args, "max_turns") ||
            Map.get(args, "max_iterations") ||
            (agent_def && agent_def[:max_iterations])
        ) || Tier.max_iterations(tier),
      isolation: isolation,
      merge_worktree: Map.get(args, "merge_worktree") == true,
      discard_worktree: Map.get(args, "discard_worktree") == true,
      working_dir: Map.get(args, "cwd") || Map.get(args, "working_dir"),
      # Preserve the agent definition's background default so background?/2 can
      # fall back to it when the caller omits an explicit "background" arg.
      background: (agent_def && agent_def[:background]) || false,
      # Parent's depth — Orchestrator.run_subagent increments this for the child
      # so ToolFilter can strip spawning tools once the max nesting is reached.
      delegation_depth: parent_depth
    }
  end

  defp background?(args, config) do
    case Map.fetch(args, "background") do
      {:ok, value} -> value == true
      :error -> Map.get(config, :background, false) == true
    end
  end

  # Normalize the optional `tasks:[]` fan-out param into a list of
  # %{prompt, subagent_type} maps, dropping anything without a usable prompt.
  defp normalize_tasks(tasks) when is_list(tasks) do
    tasks
    |> Enum.map(fn
      %{"prompt" => p} = t when is_binary(p) ->
        %{prompt: p, subagent_type: t["subagent_type"] || t["role"], name: t["name"]}

      %{"task" => p} = t when is_binary(p) ->
        %{prompt: p, subagent_type: t["subagent_type"] || t["role"], name: t["name"]}

      p when is_binary(p) ->
        %{prompt: p, subagent_type: nil, name: nil}

      _ ->
        nil
    end)
    |> Enum.reject(fn
      nil -> true
      %{prompt: p} -> String.trim(p) == ""
    end)
  end

  defp normalize_tasks(_), do: []

  # Fan out `tasks` as a parallel wave. Reuses the already-wired
  # Orchestrator.run_parallel/3 (wave + synthesis TUI) with a stable batch_id.
  defp dispatch_fanout(umbrella_task, tasks, args, parent_id, parent_depth) do
    batch_id = "batch:#{parent_id}:#{System.unique_integer([:positive])}"

    configs =
      Enum.map(tasks, fn %{prompt: prompt, subagent_type: st} = t ->
        role = st || Map.get(args, "role") || Map.get(args, "subagent_type")
        build_config(prompt, role, args, parent_id, parent_depth, Map.get(t, :name))
      end)

    # await_timeout defaults to :infinity in run_parallel so long teammates
    # aren't killed at 10 min; an optional timeout_ms arg bounds it.
    parallel_opts =
      [batch_id: batch_id] ++
        case parse_timeout_ms(Map.get(args, "timeout_ms")) do
          nil -> []
          ms -> [await_timeout: ms]
        end

    results = Orchestrator.run_parallel(parent_id, configs, parallel_opts)

    if reconcile?(args) and Enum.any?(results, &match?({:ok, _}, &1)) do
      dispatch_reconcile(umbrella_task, tasks, results, args, parent_id, parent_depth)
    else
      {:ok, format_fanout(umbrella_task, tasks, results)}
    end
  end

  # Opt-in coordinator closeout (all-hands pattern). After the parallel wave
  # finishes, run ONE more subagent that reads every workstream report and
  # produces a single reconciled/merged deliverable — resolving conflicts,
  # deduping overlap, and listing follow-ups. Reuses run_subagent (so it shows
  # up as its own agent in the fleet TUI). Falls back to plain concatenation if
  # the coordinator itself fails, so a reconcile pass never loses the raw work.
  defp reconcile?(args), do: Map.get(args, "reconcile") == true

  defp dispatch_reconcile(umbrella_task, tasks, results, args, parent_id, parent_depth) do
    reports = format_fanout(umbrella_task, tasks, results)
    coord_role = Map.get(args, "coordinator_role") || Map.get(args, "role") || "coordinator"
    coord_task = reconcile_prompt(umbrella_task, length(tasks), reports)

    coord_config =
      build_config(coord_task, coord_role, args, parent_id, parent_depth, "coordinator")
      # The coordinator reconciles the text reports; it must not inherit the
      # workstreams' worktree isolation or merge/discard flags.
      |> Map.merge(%{isolation: nil, merge_worktree: false, discard_worktree: false})

    case Orchestrator.run_subagent(coord_config) do
      {:ok, summary} ->
        {:ok, format_reconciled(umbrella_task, tasks, summary, results)}

      _ ->
        {:ok, format_fanout(umbrella_task, tasks, results)}
    end
  end

  defp reconcile_prompt(umbrella_task, n, reports) do
    """
    You are the coordinator for #{n} parallel workstream#{if n == 1, do: "", else: "s"} \
    that ran to complete this overall goal:

    #{umbrella_task}

    Read all of the workstream reports below and produce ONE integrated result.
    Reconcile any conflicts, dedupe overlapping work, note anything that is still
    inconsistent or incomplete, and end with a short list of follow-ups. Do NOT
    just concatenate the reports — synthesize them into a single coherent deliverable.

    ## Workstream reports
    #{reports}
    """
  end

  defp format_reconciled(umbrella_task, tasks, summary, results) do
    header =
      "Reconciled closeout of #{length(tasks)} workstream#{if length(tasks) == 1, do: "", else: "s"} for: " <>
        String.slice(umbrella_task, 0, 120)

    appendix = format_fanout(umbrella_task, tasks, results)

    Enum.join(
      [header, "## Coordinator summary\n#{summary}", "## Per-workstream reports (appendix)\n#{appendix}"],
      "\n\n"
    )
  end

  defp format_fanout(umbrella_task, tasks, results) do
    header =
      "Fan-out of #{length(tasks)} subagent#{if length(tasks) == 1, do: "", else: "s"} for: " <>
        String.slice(umbrella_task, 0, 120)

    sections =
      tasks
      |> Enum.zip(results)
      |> Enum.with_index(1)
      |> Enum.map(fn {{task, result}, idx} ->
        label = task.subagent_type || "agent"

        text =
          case result do
            {:ok, str} -> str
            {:error, reason} -> "Failed: #{inspect(reason)}"
            other -> inspect(other)
          end

        "### #{idx}. #{label} — #{String.slice(task.prompt, 0, 80)}\n#{text}"
      end)

    Enum.join([header | sections], "\n\n")
  end

  defp delegation_depth(ctx) do
    case Map.get(ctx, :delegation_depth, 0) do
      d when is_integer(d) and d >= 0 -> d
      _ -> 0
    end
  end

  defp dispatch_foreground(config) do
    case Orchestrator.run_subagent(config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:ok, "Delegation failed: #{inspect(reason)}"}
    end
  end

  defp dispatch_background(parent_id, config) do
    {:ok, agent_id} = Orchestrator.run_background(parent_id, config)

    {:ok,
     "Agent '#{config.role}' spawned in background (#{agent_id}). " <>
       "You'll be notified when it completes. Continue with other work."}
  end

  defp resolve_parent_id(_args, %UseContext{session_id: sid}) when is_binary(sid), do: sid
  defp resolve_parent_id(args, _ctx), do: Map.get(args, "__session_id__", "unknown")

  defp parse_timeout_ms(nil), do: nil
  defp parse_timeout_ms(ms) when is_integer(ms) and ms > 0, do: ms

  defp parse_timeout_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_timeout_ms(_), do: nil

  defp parse_tier("elite"), do: :elite
  defp parse_tier("specialist"), do: :specialist
  defp parse_tier("utility"), do: :utility
  defp parse_tier(tier) when is_atom(tier), do: tier
  defp parse_tier(_), do: :specialist

  defp parse_permission_tier(nil), do: :subagent
  defp parse_permission_tier("default"), do: :subagent
  defp parse_permission_tier("acceptEdits"), do: :workspace
  defp parse_permission_tier("bypassPermissions"), do: :full
  defp parse_permission_tier("plan"), do: :read_only
  defp parse_permission_tier("read_only"), do: :read_only
  defp parse_permission_tier("read-only"), do: :read_only
  defp parse_permission_tier("workspace"), do: :workspace
  defp parse_permission_tier("subagent"), do: :subagent
  defp parse_permission_tier("full"), do: :full
  defp parse_permission_tier("auto"), do: :auto

  defp parse_permission_tier(tier) when tier in [:read_only, :workspace, :subagent, :full, :auto],
    do: tier

  defp parse_permission_tier(_), do: :subagent

  defp parse_max_iterations(value) when is_integer(value), do: value

  defp parse_max_iterations(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_max_iterations(_), do: nil

  defp fetch_parent_messages(parent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, parent_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)

          state.messages
          |> Enum.reject(fn msg ->
            role = Map.get(msg, :role) || Map.get(msg, "role")
            role == "system"
          end)
          |> Enum.take(-20)
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end
end
