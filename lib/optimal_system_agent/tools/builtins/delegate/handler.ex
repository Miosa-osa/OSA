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
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Agents.Config, as: AgentConfig
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Agent.DelegationPolicy
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.TaskNotifications
  alias OptimalSystemAgent.Agent.Loop

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

        # P6 peer-resume (sibling handoff) — seeding from a named peer's saved
        # context takes precedence over an ordinary parent-fork; a caller
        # asking for both almost certainly wants the peer handoff (e.g. "seed
        # the fixer from the debugger's findings", not the parent's own turn).
        config =
          cond do
            is_binary(Map.get(args, "resume_from_agent_id")) and
                String.trim(Map.get(args, "resume_from_agent_id")) != "" ->
              peer_id = Map.get(args, "resume_from_agent_id")

              config
              |> Map.put(:fork_messages, fetch_peer_messages(peer_id))
              |> Map.put(:resumed_from, peer_id)

            Map.get(args, "fork") == true ->
              Map.put(config, :fork_messages, fetch_parent_messages(parent_id))

            true ->
              config
          end

        if background?(args, config) do
          dispatch_background(parent_id, config)
        else
          dispatch_foreground(config)
        end

      tasks ->
        # Quality gate BEFORE dispatch: one bad entry in a fan-out otherwise
        # burns a whole subagent run to produce nothing.
        bad =
          tasks
          |> Enum.with_index()
          |> Enum.flat_map(fn {t, idx} ->
            case task_quality_issue(t.prompt) do
              nil -> []
              issue -> [{idx, t.prompt, issue}]
            end
          end)

        if bad != [] do
          reject_low_quality_tasks(bad)
        else
          # ── Fan-out path — first-class parallel wave via run_parallel ──
          dispatch_fanout(task, tasks, args, parent_id, parent_depth)
        end
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
        tier_override = AgentConfig.tier_override(role) -> tier_override
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
      # Inject the SHARED scratchpad directory into the worker's task (CC
      # scratchpadDir dependency-injection parity). The worker resolves the same
      # directory at runtime because its own `scratchpad` tool walks the
      # RunStore parent chain back to this root (see Scratchpad.session_root/1),
      # so anything a worker drops here is readable by the coordinator and its
      # siblings.
      task: inject_scratchpad(child_task, parent_id),
      parent_session_id: parent_id,
      role: role || "agent",
      # Non-fatal signal: caller named a specific role/subagent_type but no such
      # agent definition exists — surfaced in the result so the model learns its
      # chosen specialist wasn't found (it ran a generic agent instead).
      requested_role_missing: role && is_nil(agent_def) && role != "agent" && role,
      # Stable UI handle → @name id + "Teammate @name finished" line. Per-task
      # name (fan-out) wins over a top-level "name" arg.
      name: name || Map.get(args, "name"),
      tier: tier,
      model:
        Map.get(args, "model") || AgentConfig.model_override(role) ||
          (agent_def && agent_def[:model]),
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
      # Default posture for a delegation the caller did not classify. See
      # `background?/2` — an agent definition may still opt back into
      # foreground, and an explicit `background:` arg always wins.
      background: default_background(agent_def),
      # Parent's depth — Orchestrator.run_subagent increments this for the child
      # so ToolFilter can strip spawning tools once the max nesting is reached.
      delegation_depth: parent_depth,
      # Per-call override for the subagent JOIN timeout (D1). Applies to both
      # the single-task and fan-out paths; nil lets Orchestrator fall back to
      # `:subagent_join_timeout_ms` / `@default_subagent_timeout_ms`.
      timeout_ms: parse_timeout_ms(Map.get(args, "timeout_ms"))
    }
  end

  @doc """
  Whether this delegation runs detached from the parent's turn.

  Precedence, highest first:

    1. an explicit `background` arg on the call — the model asked for a posture
       and gets it, in either direction;
    2. the agent definition's own `background:` key, when it HAS one — a
       definition that says `background: false` is asking to be joined;
    3. `true`.

  ## Why the default is `true`

  A foreground delegation blocks the parent INSIDE its tool phase, and a
  subagent's tool phase can last hours. Everything the parent's loop services
  between ReAct steps — the mid-turn steer drain, the background
  task-notification drain, cancellation — happens at the TOP of an iteration,
  which is not reached again until the child returns. So a foreground
  delegation does not merely make the parent wait: it takes the user's own
  channel to the parent offline for the child's entire life. The TUI accepts a
  typed message during that window and toasts "folding into the current turn",
  which is a promise the loop structurally cannot keep.

  Backgrounding costs nothing in reach: the result comes back as a
  `<task-notification>` that re-enters the SAME turn if the parent is still
  working (`ReactLoop.inject_pending_task_notifications/1`) and as a synthetic
  turn if it has gone idle (`Loop.poke/1`). Claude Code made the same default
  flip in 2.1.198.

  Note the third clause is `Map.has_key?`, not truthiness: `background: false`
  in a definition has to be distinguishable from a definition that never
  mentioned it, or the flip would silently override deliberate opt-outs.
  """
  @spec background?(map(), map()) :: boolean()
  def background?(args, config) do
    case Map.fetch(args, "background") do
      {:ok, value} -> value == true
      :error -> Map.get(config, :background, true) == true
    end
  end

  # An agent definition that explicitly carries `background:` keeps its choice;
  # one that is silent gets the background default.
  defp default_background(agent_def) when is_map(agent_def) do
    if Map.has_key?(agent_def, :background), do: agent_def[:background] == true, else: true
  end

  defp default_background(agent_def) when is_list(agent_def) do
    if Keyword.has_key?(agent_def, :background),
      do: agent_def[:background] == true,
      else: true
  end

  defp default_background(_), do: true

  # ── Task quality gate ─────────────────────────────────────────────────
  #
  # `normalize_tasks/1` rejected only blank strings, so `"fix it"` was a valid
  # fan-out entry. A subagent starts with NONE of the parent's context: a
  # deictic task ("this", "same as before", "continue") is unanswerable to it,
  # so the run is guaranteed waste — a whole subagent's tokens, wall-clock and
  # a parent turn spent to learn nothing. Rejecting at dispatch costs one
  # cheap tool result instead.
  #
  # The bar is deliberately low. It rejects only what CANNOT succeed, never
  # merely terse-but-complete instructions: a task naming a concrete target
  # ("run mix test", "read lib/foo.ex") passes on its verb+object alone.
  @deictic_only ~w(it this that them those these again same continue go do fix here now)

  @doc false
  @spec task_quality_issue(String.t()) :: String.t() | nil
  def task_quality_issue(prompt) when is_binary(prompt) do
    trimmed = String.trim(prompt)
    words = String.split(trimmed, ~r/\s+/, trim: true)

    content_words =
      Enum.reject(words, fn w ->
        w
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_\/.-]/, "")
        |> Kernel.in(@deictic_only)
      end)

    cond do
      trimmed == "" ->
        "the task is empty"

      content_words == [] ->
        "the task is made only of references to context the subagent does not have " <>
          "(#{inspect(trimmed)})"

      # One content word and nothing concrete to act on. Word count ALONE is not
      # the test — "read lib/foo.ex" is two words and perfectly actionable —
      # so a path, module, file or flag-looking token clears the gate.
      length(content_words) < 2 and not Enum.any?(content_words, &concrete_token?/1) ->
        "the task is #{length(words)} word(s) and names no concrete target — a subagent " <>
          "starts with none of your context, so it cannot infer what #{inspect(trimmed)} " <>
          "refers to"

      true ->
        nil
    end
  end

  def task_quality_issue(_), do: "the task is not a string"

  # A token that identifies something specific on its own: a path, a dotted
  # module/file name, a snake_case identifier, or a flag.
  defp concrete_token?(word) do
    String.contains?(word, "/") or String.contains?(word, ".") or
      String.contains?(word, "_") or String.contains?(word, "::") or
      String.starts_with?(word, "-")
  end

  # Turn a list of {index, prompt, issue} into one actionable rejection.
  defp reject_low_quality_tasks(bad) do
    details =
      Enum.map_join(bad, "\n", fn {idx, prompt, issue} ->
        "  - tasks[#{idx}] #{inspect(prompt)}: #{issue}"
      end)

    {:error,
     "delegate refused #{length(bad)} fan-out task(s) that would have wasted a full " <>
       "subagent run each:\n#{details}\n\n" <>
       "A subagent shares no context with you. Next step: rewrite each rejected task as a " <>
       "self-contained instruction naming the concrete goal, the files or commands involved, " <>
       "and what a finished result looks like — then call delegate again."}
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

    if fanout_background?(args, configs) do
      dispatch_fanout_background(
        batch_id,
        umbrella_task,
        tasks,
        args,
        parent_id,
        parent_depth,
        configs,
        parallel_opts
      )
    else
      run_fanout(umbrella_task, tasks, args, parent_id, parent_depth, configs, parallel_opts)
    end
  end

  # The wave itself. Blocks until every workstream joins — only ever called from
  # the foreground path, or from inside the detached Task the background path
  # starts.
  defp run_fanout(umbrella_task, tasks, args, parent_id, parent_depth, configs, parallel_opts) do
    results = Orchestrator.run_parallel(parent_id, configs, parallel_opts)

    if reconcile?(args) and Enum.any?(results, &match?({:ok, _}, &1)) do
      dispatch_reconcile(umbrella_task, tasks, results, args, parent_id, parent_depth)
    else
      {:ok, format_fanout(umbrella_task, tasks, results)}
    end
  end

  @doc """
  Whether a `tasks:[]` fan-out runs detached from the parent's turn.

  Resolved with the same rule as the single-delegate `background?/2`, applied to
  every workstream: an explicit `background` arg on the call wins outright, and
  otherwise a wave runs in the background unless SOME workstream's agent
  definition explicitly asked to be joined. Resolution is by KEY PRESENCE, so a
  definition carrying `background: false` keeps its opt-out; a definition that
  never mentions it does not drag the wave into the foreground.

  ## Why this matters more here than anywhere else

  `delegate` already defaults a single teammate to background, for the reason in
  `background?/2`: a foreground delegation blocks the parent inside its tool
  phase, so the steer drain, the task-notification drain and cancellation are
  all unreachable until the child returns — the user's channel to the agent goes
  offline for the child's entire life.

  The fan-out went through `run_parallel/3` synchronously, so it kept exactly
  that defect on the path where it hurts most: a wave is N teammates, it joins
  the SLOWEST of them, and it is what a model reaches for on the biggest jobs.
  A wave of long workstreams could hold the conversation for hours.
  """
  @spec fanout_background?(map(), [map()]) :: boolean()
  def fanout_background?(args, configs) do
    case Map.fetch(args, "background") do
      {:ok, value} -> value == true
      :error -> configs != [] and Enum.all?(configs, &background?(args, &1))
    end
  end

  # Run the wave detached and return the launch notice immediately.
  #
  # The fan-out TUI is unaffected: every wave/agent/synthesis event
  # `run_parallel/3` emits goes out on the parent's PubSub topic from whichever
  # process is running it, and none of it is carried on the return value. The
  # only thing that moves is WHERE the report is delivered — instead of being
  # the tool result, it arrives as a `<task-notification>` through the same
  # queue+poke path a background subagent and a background shell command use, so
  # it re-enters the current turn if the parent is still working and wakes an
  # idle parent if it is not.
  defp dispatch_fanout_background(
         batch_id,
         umbrella_task,
         tasks,
         args,
         parent_id,
         parent_depth,
         configs,
         parallel_opts
       ) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      summary =
        try do
          {:ok, report} =
            run_fanout(
              umbrella_task,
              tasks,
              args,
              parent_id,
              parent_depth,
              configs,
              parallel_opts
            )

          report
        rescue
          e -> "Fan-out crashed: #{Exception.message(e)}"
        catch
          :exit, reason -> "Fan-out exited: #{inspect(reason)}"
        end

      # `mark_notified/1` is the same exactly-once token the subagent and shell
      # paths arbitrate on, keyed here by the stable batch id.
      if TaskNotifications.mark_notified(batch_id) do
        TaskNotifications.queue(parent_id, %{
          task_id: batch_id,
          status: :completed,
          summary: summary
        })

        Loop.poke(parent_id)
      end
    end)

    {:ok, fanout_launch_notice(batch_id, length(tasks))}
  end

  @doc """
  The tool result the lead reads the instant a background wave starts.

  Same discipline as `async_launch_notice/3`: no "end your response" branch (a
  model takes it almost every time, leaving the user holding a launch notice
  instead of an answer), and no polling before the notification lands.
  """
  @spec fanout_launch_notice(String.t(), pos_integer()) :: String.t()
  def fanout_launch_notice(batch_id, count) do
    """
    Parallel wave launched.
    batchId: #{batch_id}
    workstreams: #{count}

    #{count} teammate#{if count == 1, do: " is", else: "s are"} running in the \
    background. A <task-notification> carrying every workstream's report will be \
    injected into this conversation when the wave finishes — do NOT poll for it, \
    and do not redo any of this work yourself. Mention the launch to the user in \
    one clause, then KEEP WORKING: pick up the next thing that does not depend on \
    these results. Launching a wave is never a reason to stop or to wait.
    """
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
      [
        header,
        "## Coordinator summary\n#{summary}",
        "## Per-workstream reports (appendix)\n#{appendix}"
      ],
      "\n\n"
    )
  end

  defp format_fanout(umbrella_task, tasks, results) do
    header =
      "Fan-out of #{length(tasks)} subagent#{if length(tasks) == 1, do: "", else: "s"} for: " <>
        String.slice(umbrella_task, 0, 120)

    failed = Enum.count(results, &match?({:error, _}, &1))

    failure_note =
      if failed > 0,
        do:
          "\n\n(⚠ #{failed} of #{length(tasks)} workstream#{if failed == 1, do: "", else: "s"} " <>
            "FAILED — do not treat their sections below as completed work.)",
        else: ""

    sections =
      tasks
      |> Enum.zip(results)
      |> Enum.with_index(1)
      |> Enum.map(fn {{task, result}, idx} ->
        label = task.subagent_type || "agent"

        # A crashed/timed-out/cancelled subagent must never read as a normal
        # completed section (D2) — every failure path is prefixed with a
        # loud, unambiguous "FAILED" marker distinct from real output.
        text =
          case result do
            {:ok, str} -> str
            {:error, reason} -> "**FAILED** — #{failure_reason(reason)}"
            other -> "**FAILED** — #{inspect(other)}"
          end

        "### #{idx}. #{label} — #{String.slice(task.prompt, 0, 80)}\n#{text}"
      end)

    Enum.join([header <> failure_note | sections], "\n\n")
  end

  # Human-readable classification mirroring
  # `Orchestrator.failure_reason_text/1` — the machine-shaped reasons a
  # subagent join can now fail with (D1/D2: real timeout, cancel-terminated,
  # crashed) get a clear sentence instead of a bare `inspect/1` atom.
  defp failure_reason(:timeout),
    do: "did not finish within its join timeout and was terminated"

  defp failure_reason(:cancelled),
    do: "was cancelled (interrupt/Esc) and terminated before finishing"

  defp failure_reason({:crashed, reason}), do: "process crashed/exited: #{inspect(reason)}"
  defp failure_reason(reason), do: inspect(reason)

  defp delegation_depth(ctx) do
    case Map.get(ctx, :delegation_depth, 0) do
      d when is_integer(d) and d >= 0 -> d
      _ -> 0
    end
  end

  defp dispatch_foreground(config) do
    note = role_missing_note(config) <> resumed_from_note(config)

    config |> Orchestrator.run_subagent() |> foreground_result(note)
  end

  @doc """
  Classify a foreground delegation's outcome as a tool result.

  A failed delegation is an ERROR result, not a successful one whose text
  happens to say "failed". This used to return
  `{:ok, "Delegation failed: \#{inspect(reason)}"}`, which laundered the
  failure: the model received a SUCCESSFUL tool result and went on to build its
  next step on work that never happened — the worst failure mode available,
  because nothing downstream can tell it apart from real output.

  `Orchestrator.dispatch` already classifies a subagent timeout as a genuine
  `{:error, :timeout}` for exactly this reason, and `Swarm.Patterns` had the
  identical laundering removed from its parallel path.
  """
  @spec foreground_result({:ok, String.t()} | {:error, term()}, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def foreground_result({:ok, result}, note), do: {:ok, note <> result}

  def foreground_result({:error, reason}, _note),
    do: {:error, "Delegation failed: #{inspect(reason)}"}

  # P6 peer-resume — non-fatal signal so the model can see (and later refer to)
  # which peer's context seeded this subagent, and confirm the handoff worked
  # even when the peer had no saved transcript yet (empty seed, silent no-op).
  defp resumed_from_note(config) do
    case Map.get(config, :resumed_from) do
      peer_id when is_binary(peer_id) ->
        seeded = length(Map.get(config, :fork_messages, []))

        "[note: seeded from peer agent '#{peer_id}'s context — #{seeded} message(s) carried over]\n\n"

      _ ->
        ""
    end
  end

  # Prefix a non-fatal note when the requested role/subagent_type had no matching
  # agent definition (typed-registry-miss signal for the model).
  defp role_missing_note(config) do
    case Map.get(config, :requested_role_missing) do
      role when is_binary(role) ->
        "[note: requested agent '#{role}' was not found in the registry — ran a generic agent instead]\n\n"

      _ ->
        ""
    end
  end

  # Async-launch result contract (CC AgentTool asyncOutputSchema parity):
  # agentId + output_file + anti-duplication + don't-poll discipline.
  defp dispatch_background(parent_id, config) do
    {:ok, agent_id} = Orchestrator.run_background(parent_id, config)
    output_file = OptimalSystemAgent.Agent.RunStore.transcript_path_for(agent_id)

    {:ok, async_launch_notice(config.role, agent_id, output_file)}
  end

  @doc """
  The tool result the lead agent reads the instant a background teammate starts.

  This string decides what the lead does for the next several minutes, so it is
  a named function rather than an inline heredoc — it is behaviour, and it is
  tested as behaviour.

  It used to end with *"then continue with other work or end your response."*
  Claude Code shipped that exact instruction and then removed it (2.1.193:
  "the launch result no longer instructs Claude to 'end your response' — it
  keeps working while the agent runs"), for the reason that shows up
  immediately in practice: offered the choice, a model takes the second branch
  almost every time. The user asks for something, the lead delegates it, and
  the turn ENDS — the session goes quiet with work in flight, and the user is
  left holding a launch notice instead of an answer.

  So the choice is gone. What survives untouched is the anti-poll discipline:
  polling `task_output` or reading the transcript before the notification lands
  burns the parent's context re-reading a file that is still being written.
  """
  @spec async_launch_notice(String.t(), String.t(), String.t()) :: String.t()
  def async_launch_notice(role, agent_id, output_file) do
    """
    Async agent launched.
    agentId: #{agent_id}
    output_file: #{output_file}

    The '#{role}' agent is running in the background. A <task-notification> \
    will be injected into this conversation when it completes — do NOT poll for it \
    with task_output, and do NOT read the output file before that notification \
    arrives. Do not duplicate this agent's work yourself. Mention the launch to the \
    user in one clause, then KEEP WORKING: pick up the next thing that does not \
    depend on this agent's result. Launching a teammate is never a reason to stop \
    or to wait — the notification will reach you wherever you are. \
    Use task_resume (or message_agent send to: "#{agent_id}") to continue it later \
    with its full context.
    """
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

          # WS7 — full-context fork (CC forkSubagent parity): the child inherits
          # the parent's ENTIRE non-system conversation, not a 20-message tail.
          state.messages
          |> Enum.reject(fn msg ->
            role = Map.get(msg, :role) || Map.get(msg, "role")
            role == "system"
          end)
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end

  # P6 peer-resume (sibling handoff) — seed a fresh subagent from a SIBLING's
  # accumulated context instead of the parent's, e.g. a debugger's findings
  # seed the fixer. Unlike `fetch_parent_messages/1` (reads a LIVE Loop's
  # in-memory state), the peer has typically already finished, so this reads
  # its persisted transcript snapshot from `RunStore.save_messages/3` — the
  # same durable store `Orchestrator.resume_subagent/2` uses for same-agent
  # resume. System messages are dropped and unresolved tool_use pairs are
  # stripped (reusing the exact same filter resume_subagent applies) so the
  # seeded child never sees a dangling tool call it can't respond to. Returns
  # `[]` (fresh-context fallback, never raises/errors the delegation) when the
  # peer has no saved transcript yet (still running) or is unknown.
  #
  # Public only for tests (mirrors `Orchestrator.filter_unresolved_tool_uses/1`)
  # — exercising this end-to-end would require spawning a real subagent Loop.
  @doc false
  def fetch_peer_messages(agent_id) when is_binary(agent_id) do
    case RunStore.load_messages(agent_id) do
      {:ok, messages, _meta} ->
        messages
        |> Enum.reject(fn msg ->
          role = Map.get(msg, :role) || Map.get(msg, "role")
          role == "system"
        end)
        |> Orchestrator.filter_unresolved_tool_uses()

      _ ->
        []
    end
  end

  @doc false
  def fetch_peer_messages(_), do: []

  # ── Shared scratchpad injection (CC scratchpadDir parity) ───────────────

  # Resolve the SHARED scratchpad directory for this delegation and prepend a
  # short preamble to the worker's task so the worker knows where to read/write
  # shared findings. The directory is keyed by the coordinator's SESSION ROOT so
  # every worker (and the reconcile coordinator) resolves the SAME directory —
  # both here (parent side) and at the worker's runtime via
  # `Scratchpad.session_root/1`.
  #
  # Public (`@doc false`) so the delegate-wiring test can assert the injected
  # path equals the parent's resolved scratchpad dir without spawning a real LLM.
  @doc false
  @spec inject_scratchpad(String.t(), String.t()) :: String.t()
  def inject_scratchpad(child_task, parent_id) do
    dir = scratchpad_dir_for(parent_id)
    scratchpad_preamble(dir) <> child_task
  rescue
    # Never let scratchpad wiring fail a delegation — fall back to the raw task.
    _ -> child_task
  end

  @doc false
  @spec scratchpad_dir_for(String.t()) :: String.t()
  def scratchpad_dir_for(parent_id) do
    Scratchpad.ensure_dir(Scratchpad.session_root(parent_id))
  end

  defp scratchpad_preamble(dir) do
    """
    [shared scratchpad] You are part of a coordinated team. A real, shared \
    directory is available at:

      #{dir}

    Use the `scratchpad` tool (write/append/read/list) to publish findings, \
    plans, and partial results your coordinator and sibling agents can read, \
    and to read what they have already published. It resolves to this same \
    directory automatically — do not pass a path.

    """
  end
end
