defmodule OptimalSystemAgent.Orchestrator do
  @moduledoc """
  Subagent lifecycle management — spawn, monitor, collect results, cleanup.

  Spawns subagent Loop processes under the existing SessionSupervisor,
  forwards tool_call events as orchestrator_agent_progress, and emits
  the standard orchestrator_* events that the TUI already handles.

  Subagents are regular Loop GenServers with :subagent permission tier.
  They get their own context window, model selection, and tool access.
  """
  require Logger
  import Bitwise, only: [bsl: 2]

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.ExecutionControl
  alias OptimalSystemAgent.Agent.SubagentControl
  alias OptimalSystemAgent.Agent.ActiveSkills
  alias OptimalSystemAgent.Agent.BackgroundNotifier
  alias OptimalSystemAgent.Agent.Orchestrator.ResultSummarizer
  alias OptimalSystemAgent.Events.Bus

  # Real, configurable backstop for a subagent JOIN — deliberately NOT
  # `:infinity`. A stuck child (bad provider, hung tool, nested blocking
  # join) must eventually surface as a clear timeout instead of hanging the
  # parent turn forever. 2h is generous enough to not regress a genuinely
  # long-running teammate; raise `:subagent_join_timeout_ms` /
  # `:subagent_await_timeout_ms` (or pass `timeout_ms:` / `await_timeout:`
  # per call) for jobs that legitimately need longer. The PRIMARY unblock
  # mechanism for an explicit user cancel is `Loop.cancel/1` force-terminating
  # the child's GenServer (loop.ex) — this timeout is the backstop for the
  # no-cancel-issued, just-plain-stuck case.
  # Raised from 2h. This is the "just plain stuck, no cancel issued" backstop,
  # and at two hours it was firing on work that was merely long: a background
  # agent building 67 pages and running 157 tests hit it and was reported as
  # `:timeout` with its finished results thrown away.
  #
  # An agent expected to work unattended for a shift needs a backstop measured
  # in shifts. Still finite so a truly wedged child cannot be held forever, and
  # still overridable per call (`timeout_ms:` / `await_timeout:`) or globally via
  # `:subagent_await_timeout_ms` for a deliberately bounded job.
  @default_subagent_timeout_ms 12 * 60 * 60 * 1000

  @doc false
  def runner_key(agent_id), do: "subagent-runner:" <> agent_id

  # Slack between the INNER join deadline (inside the task, in
  # `execute_and_collect/6`) and the OUTER one (`join_subagent_task/3`). The
  # inner path must always fire first: it is the only one that force-terminates
  # the orphaned child, snapshots its transcript and settles its run row. The
  # same window is reused as the post-deadline grace before anything is reaped.
  @join_grace_ms 60_000

  @doc """
  Run a subagent to completion and return its result.

  Config map keys:
    - :task (required) — the task description sent to the subagent
    - :parent_session_id (required) — routes events to parent's SSE stream
    - :role — display name (e.g., "architect", "backend")
    - :tier — :elite | :specialist | :utility (default :specialist)
    - :model — explicit model override (otherwise resolved from tier)
    - :provider — provider override (otherwise uses app default)
    - :max_iterations — override tier default
    - :system_prompt — override from AGENT.md
    - :tools_allowed — allowlist from AGENT.md (nil = all)
    - :tools_blocked — denylist from AGENT.md
  """
  alias OptimalSystemAgent.Team

  # Tool inventory a read-only panel spawn is allowed to carry, mirroring
  # ToolExecutor's @read_only_tools. Intersected against every config's
  # :tools_allowed in run_read_only_panel/2 so a caller can never grant a
  # "read-only panel" a write/exec tool, even by mistake.
  @read_only_panel_tools ~w(
    file_read file_glob dir_list file_grep file_search
    memory_recall session_search semantic_search
    code_symbols web_fetch web_search list_skills
    list_dir read_file grep_search
  )

  @doc """
  Run multiple subagents in parallel and collect all results.

  Takes a list of config maps (same format as run_subagent/1).
  Returns a list of {:ok, result} | {:error, reason} in the same order.

  Emits wave events for TUI display when wave numbers are present.
  """
  @spec run_parallel(String.t(), [map()], keyword()) :: [{:ok, String.t()} | {:error, term()}]
  def run_parallel(parent_id, configs, opts \\ []) when is_list(configs) do
    # Group by wave number (default wave 1)
    waves =
      configs
      |> Enum.with_index()
      |> Enum.group_by(fn {config, _idx} -> Map.get(config, :wave, 1) end)
      |> Enum.sort_by(fn {wave, _} -> wave end)

    total_waves = length(waves)

    # Team / batch id for task tracking. A caller-supplied batch_id (e.g. the
    # delegate fan-out path) is honoured so its wave/synthesis TUI ties to a
    # stable id; otherwise generate one.
    team_id =
      Keyword.get(opts, :batch_id) ||
        "team:#{parent_id}:#{System.unique_integer([:positive])}"

    # Emit task started
    emit_event(parent_id, %{
      event: "orchestrator_task_started",
      task_id: team_id
    })

    # Execute waves sequentially, tasks within each wave in parallel
    all_results =
      Enum.flat_map(waves, fn {wave_num, indexed_configs} ->
        # Emit wave start
        if total_waves > 1 do
          emit_event(parent_id, %{
            event: "orchestrator_wave_started",
            wave_number: wave_num,
            total_waves: total_waves,
            agent_count: length(indexed_configs)
          })
        end

        # Wait for all tasks in this wave. Timeout is configurable and defaults
        # to a real, finite backstop (`@default_subagent_timeout_ms`, not
        # `:infinity`) so a genuinely stuck teammate cannot hang the parent
        # turn forever. A caller that legitimately needs longer (e.g. a
        # multi-hour job via delegate `tasks:[]`) passes `await_timeout:` or
        # raises `:subagent_await_timeout_ms`; the recommended path for
        # unknown-horizon work is still run_background/2 (re-enters via
        # BackgroundNotifier, no join at all).
        await_timeout =
          Keyword.get(opts, :await_timeout) ||
            Application.get_env(
              :optimal_system_agent,
              :subagent_await_timeout_ms,
              @default_subagent_timeout_ms
            )

        # Bounded fan-out. `:max_fleet_agents` (default 16) was enforced ONLY on
        # the `fleet` path (Agent.Fleet), never here — and `delegate` (the path
        # the model actually reaches for) lands here. A single `delegate` call
        # with 200 tasks in one wave therefore span 200 concurrent subagent
        # Loops, each with its own provider connection, context window and token
        # spend, with nothing to stop it. Waves already run sequentially; now
        # each wave runs at most `cap` agents at a time and the rest QUEUE,
        # exactly as the fleet path does. Ordering is preserved because results
        # are re-sorted by original index below.
        cap = delegate_concurrency_cap()

        # Sliding-window fan-out. This used to `Enum.chunk_every(cap)` and run
        # the wave in fixed batches, joining every agent in a batch before
        # starting the next — so a fast agent stuck in a batch behind a slow one
        # sat idle until the whole batch drained, wasting up to (batch-1) slots.
        # `async_stream` instead keeps up to `cap` agents running at ALL times,
        # refilling a slot the instant one finishes.
        #
        # Each stream worker owns its own subagent Task and runs the SAME
        # two-clock `join_subagent_task/3` ladder it always did, so the
        # per-config inner timeout and the brutal-kill backstop are preserved
        # exactly (Task.yield/shutdown require the owner process, which is this
        # worker). `timeout: :infinity` defers entirely to that inner ladder,
        # which always returns; `ordered: true` yields results in input order —
        # already original-index order within a wave — so no post-sort is needed.
        # batch_id (team_id) + wave are threaded onto each config so the TUI can
        # group per-workstream and per-wave.
        OptimalSystemAgent.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          indexed_configs,
          fn {config, _original_idx} ->
            config =
              config
              |> Map.put(:parent_session_id, parent_id)
              |> Map.put(:batch_id, team_id)
              |> Map.put(:wave, wave_num)

            inner_timeout = subagent_join_timeout_ms(config)

            task =
              Task.Supervisor.async_nolink(
                OptimalSystemAgent.TaskSupervisor,
                fn -> run_subagent(config) end
              )

            join_subagent_task(task, await_timeout, inner_timeout)
          end,
          max_concurrency: cap,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.map(fn
          {:ok, result} -> result
          # A stream worker crashing (not the child — join_subagent_task already
          # turns a child crash into {:error, {:crashed, _}}) is still a failure,
          # never laundered into success.
          {:exit, reason} -> {:error, {:crashed, reason}}
        end)
      end)

    # Emit synthesizing
    completed_count = Enum.count(all_results, fn r -> match?({:ok, _}, r) end)

    emit_event(parent_id, %{
      event: "orchestrator_synthesizing",
      agent_count: completed_count
    })

    # Emit task completed
    emit_event(parent_id, %{
      event: "orchestrator_task_completed",
      task_id: team_id
    })

    # Cleanup team
    Team.cleanup(team_id)

    all_results
  end

  @spec run_subagent(map()) :: {:ok, String.t()} | {:error, term()}
  def run_subagent(%{routing_error: reason}), do: {:error, {:no_capable_model, reason}}

  def run_subagent(config) do
    task = Map.fetch!(config, :task)
    parent_id = Map.fetch!(config, :parent_session_id)
    role = Map.get(config, :role, "agent")
    tier = Map.get(config, :tier, :specialist)

    # Resolve model
    provider =
      Map.get(config, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    model = Map.get(config, :model) || Tier.model_for(tier, provider)
    max_iter = Map.get(config, :max_iterations) || Tier.max_iterations(tier)

    # Generate subagent session ID, or honor a caller-provided ID for
    # background/lifecycle tooling that returns the id before execution starts.
    # An explicit `name` ("@smoke-e2e") yields a stable, human-readable id.
    subagent_id =
      Map.get(config, :agent_id) ||
        Map.get(config, :subagent_id) ||
        (config[:name] && "agent:#{parent_id}:#{sanitize_name(config[:name])}") ||
        "agent:#{parent_id}:#{next_subagent_number(parent_id)}"

    # Display handle shown in the UI as @name. Falls back to the role.
    display_name = config[:name] || role

    batch_id = Map.get(config, :batch_id)
    wave = Map.get(config, :wave)

    # Human label for this worker, shown next to its name in the TUI roster and
    # the live feed. A caller that knows what the agent IS should say so via
    # `:description`; only fall back to slicing the prompt when it doesn't.
    #
    # The fallback alone is why the roster read
    # `goal-verifier-skeptic  You are an ADVERSARIAL, INDEPENDENT reviewer (skeptic #1, COMPLETENE…`
    # — for a panel member the "task" IS a multi-paragraph system prompt, so its
    # first 80 characters are prompt boilerplate, not a description of the work.
    task_preview =
      case config[:description] do
        d when is_binary(d) -> if String.trim(d) == "", do: String.slice(task, 0, 80), else: d
        _ -> String.slice(task, 0, 80)
      end

    RunStore.start_run(%{
      agent_id: subagent_id,
      parent_session_id: parent_id,
      role: role,
      task: task,
      # P6 peer-resume (sibling handoff) — carried through from the delegate
      # handler when this run was seeded from a peer's saved context rather
      # than a fresh spawn or a parent-fork.
      resumed_from: Map.get(config, :resumed_from)
    })

    ensure_execution_control(subagent_id, config, %{
      parent_session_id: parent_id,
      task: task,
      role: role,
      provider: provider,
      model: model
    })

    Logger.info(
      "[Orchestrator] Spawning subagent #{subagent_id} role=#{role} tier=#{tier} model=#{model}"
    )

    # Fire subagent_start hook (can block spawning)
    hook_payload = %{
      subagent_id: subagent_id,
      parent_session_id: parent_id,
      role: role,
      tier: tier,
      model: model,
      task_preview: task_preview
    }

    try do
      Hooks.run(:subagent_start, hook_payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Emit: agent started. Carry display_name + batch_id/wave so the TUI can
    # label the teammate as @name and group fan-out agents per workstream/wave.
    emit_event(parent_id, %{
      event: "orchestrator_agent_started",
      agent_name: subagent_id,
      display_name: display_name,
      role: role,
      batch_id: batch_id,
      wave: wave,
      model: to_string(model),
      # Age of the RUN, not of this frame. The run row is created at DISPATCH,
      # so a subagent that waited behind the concurrency cap reports the wait it
      # actually did rather than restarting the clock when it finally starts —
      # and a re-announced agent (reconnect, replay) does not reset to zero.
      elapsed_ms: run_elapsed_ms(subagent_id),
      description: task_preview
    })

    # Kill any stale subagent with this ID (from a previous run/crash)
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, subagent_id) do
      [{old_pid, _}] ->
        Logger.warning("[Orchestrator] Cleaning up stale subagent #{subagent_id}")
        safely_terminate(old_pid)

      [] ->
        :ok
    end

    # Ensure per-agent memory directory exists (persistent across sessions)
    # Sanitize role to prevent path traversal via crafted :role values.
    safe_role = Regex.replace(~r/[^a-zA-Z0-9_\-]/, role, "_")
    agent_memory_dir = Path.expand("~/.osa/agent-memory/#{safe_role}")
    File.mkdir_p(agent_memory_dir)

    # Load agent memory if it exists (first 200 lines of MEMORY.md)
    agent_memory =
      case File.read(Path.join(agent_memory_dir, "MEMORY.md")) do
        {:ok, content} ->
          lines = String.split(content, "\n") |> Enum.take(200) |> Enum.join("\n")
          "\n\n## Agent Memory (#{role})\n#{lines}"

        {:error, _} ->
          ""
      end

    # Build system prompt with agent memory appended
    base_prompt = Map.get(config, :system_prompt) || ""
    full_prompt = if agent_memory != "", do: base_prompt <> agent_memory, else: base_prompt

    # If fork_messages provided, pass them as initial conversation history
    fork_messages = Map.get(config, :fork_messages, [])

    # Worktree isolation — create an isolated git worktree for this agent
    isolation = Map.get(config, :isolation)

    worktree_info =
      if isolation == :worktree do
        # A worktree is a COPY of the repo. On a large tree with no reflink
        # support this is the single longest step on the dispatch path and it
        # used to log only on SUCCESS — i.e. after the minutes had already
        # passed in silence.
        emit_phase(
          parent_id,
          subagent_id,
          display_name,
          :starting,
          "creating an isolated worktree"
        )

        # FastWorktree picks the fastest CoW tier the filesystem supports
        # (btrfs/reflink/copy) and falls back to a plain checkout. repo_dir is
        # the agent's resolved cwd (the user's project), NOT File.cwd! which
        # under `mix osa.serve` would be the OSA source tree.
        repo_dir = Map.get(config, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()

        # The repo this worktree is cut from may itself be an alternate root
        # whose `.osa/settings.json` is never resolved (settings come from the
        # process-global cwd). Report it rather than let it be silent.
        OptimalSystemAgent.Agent.Fleet.SettingsCoverage.check(
          repo_dir,
          "subagent #{subagent_id} worktree source"
        )

        case OptimalSystemAgent.Workspace.FastWorktree.create(subagent_id, repo_dir: repo_dir) do
          {:ok, info} ->
            Logger.info(
              "[Orchestrator] Worktree created for #{subagent_id} at #{info.path} " <>
                "(#{info.tier} tier)"
            )

            # `:fresh` records that THIS run created the tree, so only this run
            # may tear it down. A resumed subagent adopts the source run's
            # worktree (`working_dir` from the source's `worktree_path`); if a
            # caller also asks for `isolation: :worktree` on that resume, the
            # deterministic per-id path resolves to the SOURCE tree. Without
            # this flag, cancelling the resumed child would delete the source
            # child's worktree — grok guards the same case with
            # `worktree_freshly_created`.
            Map.put(info, :fresh, true)

          {:error, reason} ->
            Logger.warning(
              "[Orchestrator] Worktree creation failed: #{inspect(reason)}, running without isolation"
            )

            nil
        end
      else
        nil
      end

    # Set working directory — worktree path if isolated, otherwise default
    working_dir =
      if worktree_info,
        do: worktree_info.path,
        else:
          Map.get(config, :working_dir) ||
            OptimalSystemAgent.Workspace.Cwd.get()

    # The root the subagent will actually run under. A worktree is a fresh copy
    # of the repo, so a checked-in `.osa/settings.json` is present in it and
    # looks authoritative while being resolved from nowhere.
    OptimalSystemAgent.Agent.Fleet.SettingsCoverage.check(
      working_dir,
      "subagent #{subagent_id}"
    )

    # Spawn the subagent Loop
    subagent_opts = [
      session_id: subagent_id,
      user_id: "subagent",
      channel: :internal,
      permission_tier: Map.get(config, :permission_tier, :subagent),
      # Inherit the parent's full-auto mode so a subagent spawned under an
      # overdrive parent runs unattended on its non-interactive :internal
      # channel instead of failing closed on every mutating call. An explicit
      # config[:permission_mode] wins; otherwise overdrive is inherited when the
      # parent is in overdrive/bypass; else nil lets Loop.init pick the default.
      # Subagent structural tool restrictions still hold under overdrive (see
      # ToolExecutor.approve_tool_call/2).
      permission_mode: inherited_permission_mode(config, parent_id),
      model: model,
      provider: provider,
      parent_session_id: parent_id,
      allowed_tools: Map.get(config, :tools_allowed),
      blocked_tools: Map.get(config, :tools_blocked, []),
      system_prompt_override: if(full_prompt != "", do: full_prompt, else: nil),
      messages: fork_messages,
      working_dir: working_dir,
      max_turns: max_iter,
      # Increment delegation depth for the child. config[:delegation_depth] is
      # the *parent's* depth (0 for a top-level session, set by the delegate
      # handler from its UseContext). ToolFilter strips the child's spawning
      # tools once this reaches the configured max — the fork-bomb ceiling.
      delegation_depth: Map.get(config, :delegation_depth, 0) + 1,
      # Per-subagent spend ceiling. nil = off (the default, so nothing changes
      # for callers that don't set it); when present the child Loop aborts its
      # own run mid-loop via `Loop.Limits.budget_exceeded?` once it crosses the
      # cap, so a wide fan-out cannot burn unbounded spend. Enforced per child;
      # the parent's own budget is independent.
      max_budget_usd: Map.get(config, :max_budget_usd),
      # Speed/cost priority (routes a service_tier for OpenAI; also set the
      # quality tier + provider order in DelegationRouter).
      priority: Map.get(config, :priority)
    ]

    # Start event forwarder BEFORE spawning the subagent so it catches
    # all tool_call events from the first iteration onward.
    forwarder = start_event_forwarder(subagent_id, parent_id, role)

    case DynamicSupervisor.start_child(
           OptimalSystemAgent.SessionSupervisor,
           {Loop, subagent_opts}
         ) do
      {:ok, pid} ->
        # The Loop is up and about to make its first provider call. On a real
        # model this is where the minutes go: system prompt assembly plus
        # time-to-first-token, with no tool activity to report yet. Naming it is
        # the difference between "state unknown" and "waiting for the model".
        emit_phase(
          parent_id,
          subagent_id,
          display_name,
          :awaiting_model,
          "waiting for the first response from #{model}"
        )

        # Execute the task (blocking call)
        result =
          execute_and_collect(subagent_id, task, parent_id, role, max_iter, worktree_info,
            display_name: display_name,
            batch_id: batch_id,
            resumed_from: Map.get(config, :resumed_from),
            # Per-call override (delegate `timeout_ms` arg) wins; otherwise
            # execute_and_collect falls back to the global config /
            # @default_subagent_timeout_ms backstop.
            timeout_ms: Map.get(config, :timeout_ms)
          )

        # Fire subagent_stop hook (learning capture, telemetry)
        {tool_uses_final, tokens_final} = get_subagent_stats(subagent_id)

        hook_result =
          case result do
            {_, v} -> v
            other -> inspect(other)
          end

        try do
          Hooks.run(:subagent_stop, %{
            subagent_id: subagent_id,
            parent_session_id: parent_id,
            role: role,
            tool_uses: tool_uses_final,
            tokens_used: tokens_final,
            result: hook_result
          })
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        # Cleanup
        stop_event_forwarder(forwarder)
        safely_terminate(pid)

        finish_worktree(worktree_info, subagent_id, config, result)

        result

      {:error, {:already_started, _pid}} ->
        stop_event_forwarder(forwarder)

        RunStore.complete(
          subagent_id,
          failure_result(subagent_id, parent_id, role, :already_started)
        )

        {:error, "Subagent session #{subagent_id} already exists"}

      {:error, reason} ->
        stop_event_forwarder(forwarder)
        Logger.error("[Orchestrator] Failed to start subagent #{subagent_id}: #{inspect(reason)}")
        RunStore.complete(subagent_id, failure_result(subagent_id, parent_id, role, reason))

        # Same gated teardown as the success path. The failure path used to skip
        # the snapshot entirely, so a `discard: true` caller whose child failed
        # to even start lost the tree with no durable record at all.
        finish_worktree(worktree_info, subagent_id, config, {:error, reason})

        emit_event(parent_id, start_failure_event(subagent_id, reason))

        {:error, reason}
    end
  end

  # ── Joining a spawned subagent task ───────────────────────────────────
  #
  # The subagent's transcript snapshot is written INSIDE the task process:
  # `execute_and_collect/6` calls `force_terminate_orphan/1`,
  # `RunStore.save_messages/3` and `RunStore.complete/2` after its own inner
  # join returns. So killing the task process destroys exactly the persistence
  # `resume_subagent/2` depends on, and leaves the run row `:running` forever.
  #
  # It used to do precisely that. Both clocks defaulted to
  # `@default_subagent_timeout_ms`, but the OUTER one starts first (the inner
  # one only starts after worktree creation and the Loop spawn), so the outer
  # `Task.await/2` always expired first and `Task.shutdown(task, :brutal_kill)`
  # always won the race — making the inner timeout's careful cleanup path dead
  # code.
  #
  # Two changes fix it:
  #
  #   1. The outer deadline is forced to be strictly LONGER than the inner one
  #      (`+ @join_grace_ms`), so the inner path wins and returns a real
  #      `{:error, :timeout}` with everything persisted.
  #   2. If the outer deadline is hit anyway, the task gets a further
  #      grace window to finish persisting BEFORE anything is killed. Only a
  #      task that is still stuck after that is reaped, and loudly.
  @doc false
  # Public only so the deadline ladder can be unit-tested without booting a
  # subagent Loop.
  def join_subagent_task(task, await_timeout, inner_timeout) do
    grace = join_grace_ms()
    outer = max(await_timeout, inner_timeout + grace)

    case Task.yield(task, outer) do
      {:ok, value} ->
        value

      {:exit, reason} ->
        {:error, {:crashed, reason}}

      nil ->
        Logger.warning(
          "[Orchestrator] Subagent task passed its outer deadline (#{outer}ms) — allowing " <>
            "#{grace}ms for it to persist its transcript before reaping"
        )

        case Task.yield(task, grace) do
          {:ok, value} ->
            value

          {:exit, reason} ->
            {:error, {:crashed, reason}}

          nil ->
            # Last resort. Classified as a FAILURE (not laundered into
            # {:ok, ...}) so `completed_count` and `dispatch_fanout`'s reconcile
            # gate never treat a timed-out workstream as real completed output.
            Logger.error(
              "[Orchestrator] Subagent task did not persist within the grace window — " <>
                "reaping it. Its transcript snapshot may be incomplete."
            )

            Task.shutdown(task, :brutal_kill)
            {:error, :timeout}
        end
    end
  end

  @doc false
  # Slack between the inner and outer join deadlines, and the post-deadline
  # persist grace. Overridable so tests need not wait a minute.
  def join_grace_ms do
    Application.get_env(:optimal_system_agent, :subagent_join_grace_ms, @join_grace_ms)
  end

  @doc false
  # The inner join deadline `execute_and_collect/6` will use for this config —
  # resolved identically there, so the outer deadline can be derived from it.
  def subagent_join_timeout_ms(config) do
    Map.get(config, :timeout_ms) ||
      Application.get_env(
        :optimal_system_agent,
        :subagent_join_timeout_ms,
        @default_subagent_timeout_ms
      )
  end

  # ── Worktree end-of-life ──────────────────────────────────────────────
  #
  # A subagent's worktree is the only place its uncommitted work exists.
  # Removing it is therefore gated on the work having been captured somewhere
  # durable FIRST — grok's `update_subagent_meta_snapshot_ref` returns a boolean
  # for exactly this reason, and `remove_subagent_worktree` runs only when that
  # boolean is true. OSA used to log the snapshot failure and tear down anyway.
  #
  # The gate applies to the DESTRUCTIVE option only:
  #
  #   * `discard: true` — deletes a dirty tree. Downgraded to `false` when no
  #     snapshot ref persisted, so `teardown/2` falls back to its
  #     preserve-dirty-for-review branch. Nothing is ever silently lost.
  #   * `merge: true`   — folds the work into a real branch; the content
  #     survives the removal, so it is not gated.
  #   * default         — `teardown/2` already preserves a dirty tree.
  #
  # A clean tree has nothing to lose and is removed either way.
  defp finish_worktree(nil, _subagent_id, _config, _result), do: :ok

  defp finish_worktree(worktree_info, subagent_id, config, result) do
    if Map.get(worktree_info, :fresh, false) do
      snapshot = attempt_worktree_snapshot(worktree_info, subagent_id)

      case snapshot do
        {:ok, ref} -> RunStore.attach_worktree_snapshot(subagent_id, ref)
        _ -> :ok
      end

      merge = match?({:ok, _}, result) and Map.get(config, :merge_worktree, false)
      discard_requested = Map.get(config, :discard_worktree, false)
      captured? = match?({:ok, _}, snapshot)

      if discard_requested and not captured? do
        Logger.warning(
          "[Orchestrator] Not discarding #{subagent_id}'s worktree — no durable snapshot was " <>
            "written, so a dirty tree would be lost. Preserving #{worktree_info.path} for review."
        )
      end

      OptimalSystemAgent.Workspace.FastWorktree.teardown(worktree_info.path,
        merge: merge,
        discard: discard_requested and captured?,
        repo_dir: Map.get(worktree_info, :repo_dir)
      )
    else
      # A worktree this run adopted rather than created (resume/handoff) belongs
      # to whoever created it. Cancelling the adopter must not delete it.
      Logger.info(
        "[Orchestrator] Leaving adopted worktree #{worktree_info.path} in place " <>
          "(not created by #{subagent_id})"
      )

      :ok
    end
  rescue
    e ->
      Logger.warning("[Orchestrator] finish_worktree failed: #{Exception.message(e)}")
      :ok
  end

  # Durable-ref snapshot of the child's worktree, taken BEFORE teardown so a
  # merged or discarded tree's final state stays inspectable/resumable via
  # `git show <ref>` / `git worktree add -b tmp <ref>`, without polluting the
  # parent branch. Taken on BOTH the success and failure paths: a child that
  # failed is exactly the one whose partial work a human wants to look at.
  defp attempt_worktree_snapshot(worktree_info, subagent_id) do
    if subagent_worktree_snapshot?() do
      case OptimalSystemAgent.Workspace.FastWorktree.snapshot_ref(worktree_info.path,
             id: subagent_id,
             repo_dir: Map.get(worktree_info, :repo_dir)
           ) do
        {:ok, ref} ->
          Logger.info("[Orchestrator] Worktree snapshot for #{subagent_id}: #{ref}")
          {:ok, ref}

        {:error, reason} = err ->
          Logger.warning(
            "[Orchestrator] Worktree snapshot failed for #{subagent_id}: #{inspect(reason)}"
          )

          err
      end
    else
      :disabled
    end
  end

  @doc """
  Completion event for a subagent that never STARTED (the `Loop` child failed
  to spawn), so no usage was ever observed.

  Deliberately carries NO `:tool_uses` / `:tokens_used` keys. Those used to be
  sent as literal `0`s, and zero is a real wire value: the TUI decodes them as
  `Some(0)` and applies them, wiping the counters it had already accumulated for
  that agent. The TUI half distinguishes absent from zero, so ABSENCE is how
  "no measurement" is expressed — never a zero.

  Public + `@doc false` so the omission is pinned by a test.
  """
  @doc false
  @spec start_failure_event(String.t(), term()) :: map()
  def start_failure_event(subagent_id, reason) do
    %{
      event: "orchestrator_agent_completed",
      agent_name: subagent_id,
      status: "failed",
      error: inspect(reason),
      summary: completion_summary(inspect(reason))
    }
  end

  @doc """
  Spawn N independent READ-ONLY subagents in parallel and collect their
  results — the generic primitive behind the goal-level verifier
  (`Agent.Loop.GoalVerifier`)'s adversarial skeptic panel, but reusable by
  any caller needing a read-only judgement/inspection panel.

  This is a thin, defense-in-depth wrapper over `run_parallel/3`: every
  config is force-locked to `permission_tier: :read_only` and its
  `:tools_allowed` is intersected with the read-only tool set, REGARDLESS of
  what the caller passed — a caller cannot accidentally (or via a crafted
  config) grant a "read-only panel" member a write or exec tool. This backs
  up (does not replace) `ToolExecutor.permission_tier_allows?/2`'s per-call
  enforcement.

  Returns a list of `{:ok, result} | {:error, reason}` in the same order as
  `configs`, same contract as `run_parallel/3`.
  """
  @spec run_read_only_panel(String.t(), [map()], keyword()) :: [
          {:ok, String.t()} | {:error, term()}
        ]
  def run_read_only_panel(parent_id, configs, opts \\ []) when is_list(configs) do
    locked_configs =
      Enum.map(configs, fn config ->
        allowed = Map.get(config, :tools_allowed) || @read_only_panel_tools

        config
        |> Map.put(:permission_tier, :read_only)
        |> Map.put(:tools_allowed, Enum.filter(allowed, &(&1 in @read_only_panel_tools)))
      end)

    run_parallel(parent_id, locked_configs, opts)
  end

  @doc """
  Run a subagent in the background — returns immediately with the agent ID.

  The subagent runs asynchronously under TaskSupervisor. On completion,
  emits `:background_agent_completed` or `:background_agent_failed` on
  the Events.Bus, which the CLI and SSE consumers can display.
  """
  @spec run_background(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def run_background(_parent_id, %{routing_error: reason}),
    do: {:error, {:no_capable_model, reason}}

  def run_background(parent_id, config) do
    config = Map.put(config, :parent_session_id, parent_id)
    role = Map.get(config, :role, "background")
    display_name = config[:name] || role

    # Ensure a notifier is listening for this parent so the completed/failed
    # result is injected back into the parent Loop's history (delegate-and-continue).
    BackgroundNotifier.ensure_started(parent_id)

    # Generate the ID upfront so we can return it immediately. A caller-supplied
    # `name` yields a stable @handle id.
    # An explicit :agent_id (resume path) is honoured so the resumed run keeps
    # its ORIGINAL id — RunStore row, transcript file and @handle stay stable.
    subagent_id =
      Map.get(config, :agent_id) ||
        (config[:name] && "agent:#{parent_id}:#{sanitize_name(config[:name])}") ||
        "agent:#{parent_id}:#{next_subagent_number(parent_id)}"

    emit_event(parent_id, %{
      event: "background_agent_started",
      agent_id: subagent_id,
      display_name: display_name,
      role: role
    })

    # Same dual-emit as the `:background_agent_completed` / `:background_agent_failed`
    # sites below. `emit_event/2` only reaches the `osa:session:<id>` PubSub topic
    # (SSE/TUI); the CLI renderer listens on the Bus. Without this the CLI printed
    # "✓ Background agent completed" and "✗ failed" but never the "◉ started" line
    # at channels/cli/events.ex:97, which could not match anything.
    Bus.emit(:system_event, %{
      event: :background_agent_started,
      session_id: parent_id,
      agent_id: subagent_id,
      display_name: display_name,
      role: role
    })

    # Register the run at DISPATCH, not at admission.
    #
    # `RunStore.start_run/1` used to be called inside `run_subagent/1`, i.e.
    # after `await_background_slot/1` returned. So for the entire time an agent
    # sat in the admission queue — up to the full 1h budget — `RunStore.get/1`
    # answered `nil`, and every consumer read that `nil` as its own kind of
    # "no":
    #
    #   * `task_wait` treats an unknown id as terminal, so joining a queued
    #     agent returned "no run found" instantly instead of waiting for it;
    #   * `task_output` / `task_stop` reported it as nonexistent;
    #   * the stall watcher's `RunStore.get/1` fell through to its "row is gone,
    #     nothing to watch" clause and exited on its FIRST 30-second poll —
    #     permanently, so the agent was never watched for the rest of its life.
    #
    # The row is born `:queued` and `live_agent_count/0` excludes that phase, so
    # registering early cannot make queued agents count against the very cap
    # they are queued behind.
    RunStore.start_run(%{
      agent_id: subagent_id,
      parent_session_id: parent_id,
      role: role,
      task: Map.get(config, :task, ""),
      resumed_from: Map.get(config, :resumed_from),
      phase: :queued,
      phase_detail: "waiting for a concurrency slot"
    })

    ensure_execution_control(subagent_id, config, %{
      parent_session_id: parent_id,
      task: Map.get(config, :task, ""),
      role: role,
      provider: Map.get(config, :provider),
      model: Map.get(config, :model),
      recovery_state: "restartable"
    })

    start_stall_watcher(parent_id, subagent_id, display_name, role)

    # The wall clock the USER experiences starts here, at dispatch — not at
    # admission. See `dispatched_at` in the completion payload below.
    dispatched_at = System.monotonic_time(:millisecond)

    {:ok, runner_pid} =
      Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
        Registry.register(OptimalSystemAgent.SessionRegistry, runner_key(subagent_id), nil)

        # Concurrency admission. `:max_fleet_agents` (default 16) was enforced ONLY
        # on the `fleet` path — `run_background/2`, which is where the `delegate`
        # tool's `background: true` lands, had no ceiling whatsoever, so a model
        # could start unlimited concurrent subagent Loops (each with its own
        # provider connection, context window and spend) with nothing joined to
        # them to even notice.
        #
        # This QUEUES rather than refuses, exactly like Fleet's dispatcher: the
        # agent id was already returned to the caller and is already in flight in
        # the TUI, and `run_background/2`'s `{:ok, id}` contract is pattern-matched
        # by callers outside this module. Waiting here keeps the contract and still
        # bounds live concurrency.
        # Narrate the wait itself. `await_background_slot/1` can block for up to an
        # hour and used to emit nothing at all, so a queued agent was
        # indistinguishable from a wedged one from the outside.
        if not background_slot_available?() do
          emit_phase(parent_id, subagent_id, display_name, :queued, queue_detail())
        end

        await_background_slot(subagent_id)

        # Admitted. Everything from here to the first tool call — worktree
        # creation, hooks, prompt assembly, the model's first response — used to
        # be one unbroken silence. `run_subagent/1` narrates each step.
        emit_phase(parent_id, subagent_id, display_name, :starting, "preparing the workspace")

        start_time = System.monotonic_time(:millisecond)

        # Guard the ENTIRE subagent run (not just the inner Loop): run_subagent's
        # setup phase (Worktree.create, Tier.model_for, File ops) is unguarded and
        # can raise/exit. If it does, the parent's BackgroundNotifier would wait
        # forever and the RunStore entry would stick on :running. Convert any
        # raise/exit into an {:error, reason} so the failure branch below always
        # notifies the parent and reaps the run.
        result =
          try do
            run_subagent(Map.put(config, :agent_id, subagent_id))
          rescue
            e ->
              Logger.error(
                "[Orchestrator] Background subagent #{subagent_id} crashed: #{Exception.message(e)}"
              )

              {:error, Exception.message(e)}
          catch
            :exit, reason ->
              Logger.error(
                "[Orchestrator] Background subagent #{subagent_id} exited: #{inspect(reason)}"
              )

              {:error, {:exit, reason}}
          end

        duration_ms = System.monotonic_time(:millisecond) - start_time

        # How long the agent existed AS THE USER SAW IT, from the moment
        # `delegate` returned its id. `duration_ms` deliberately starts at
        # admission, so for a queued agent the two differ by the whole queue wait
        # — and it was `duration_ms` alone that got reported. An agent the user
        # watched sit on screen for four minutes reported "17s", because the
        # minutes it spent queued were measured by nobody and belonged to no
        # interval. Both numbers are now stated, and they mean different things.
        elapsed_ms = System.monotonic_time(:millisecond) - dispatched_at
        final_run = RunStore.get(subagent_id)

        # If the run raised before it could mark itself terminal, reap the RunStore
        # entry so GET /runs never sticks on :running.
        if operator_controlled?(subagent_id) do
          record_terminal_skills(subagent_id)

          ExecutionControl.progress(subagent_id, %{
            duration_ms: duration_ms,
            tokens_used: final_run && final_run.tokens_used,
            tool_count: final_run && final_run.tool_count
          })

          ExecutionControl.broadcast(subagent_id, parent_id)
          RunStore.release_lease(subagent_id)
        else
          case result do
            {:error, reason} ->
              case RunStore.get(subagent_id) do
                %{status: :running} ->
                  RunStore.complete(subagent_id, %{
                    agent_id: subagent_id,
                    status: :failed,
                    summary: "background agent failed: #{inspect(reason)}",
                    duration_ms: duration_ms
                  })

                _ ->
                  :ok
              end

            _ ->
              :ok
          end

          # WS7 - structured usage + output-file for the <task-notification> the
          # parent model receives (CC enqueueAgentNotification parity).
          final_run = RunStore.get(subagent_id)

          usage = reported_usage(final_run, duration_ms)

          output_file = RunStore.transcript_path_for(subagent_id)

          # What this teammate actually cost. `run_cost_usd/1` is durable (it reads
          # the persisted spend record) and was already being appended to the
          # FOREGROUND delegate result - but a background run rode no event
          # carrying it, so the panel could only ever show a whole-task estimate.
          # `nil` when no spend was recorded: unknown and zero are different facts
          # and the TUI renders them differently.
          cost_usd = reported_cost_usd(subagent_id)

          case result do
            {:ok, response} ->
              record_terminal_skills(subagent_id)

              ExecutionControl.finish(subagent_id, :completed, %{
                duration_ms: duration_ms,
                tokens_used: final_run && final_run.tokens_used,
                tool_count: final_run && final_run.tool_count
              })

              Bus.emit(:system_event, %{
                event: :background_agent_completed,
                session_id: parent_id,
                agent_id: subagent_id,
                display_name: display_name,
                role: role,
                result: String.slice(response, 0, 500),
                duration_ms: duration_ms
              })

              Phoenix.PubSub.broadcast(
                OptimalSystemAgent.PubSub,
                "osa:session:#{parent_id}",
                {:osa_event,
                 %{
                   type: :background_agent_completed,
                   agent_id: subagent_id,
                   display_name: display_name,
                   role: role,
                   result: String.slice(response, 0, 500),
                   duration_ms: duration_ms,
                   elapsed_ms: elapsed_ms,
                   usage: usage,
                   cost_usd: cost_usd,
                   output_file: output_file
                 }}
              )

              emit_agent_finished(
                parent_id,
                subagent_id,
                display_name,
                duration_ms,
                nil,
                :completed
              )

            {:error, reason} ->
              record_terminal_skills(subagent_id)

              ExecutionControl.increment(subagent_id, :failure_count)

              ExecutionControl.finish(subagent_id, :failed, %{
                duration_ms: duration_ms,
                tokens_used: final_run && final_run.tokens_used,
                tool_count: final_run && final_run.tool_count,
                last_error: inspect(reason)
              })

              Bus.emit(:system_event, %{
                event: :background_agent_failed,
                session_id: parent_id,
                agent_id: subagent_id,
                display_name: display_name,
                role: role,
                error: inspect(reason),
                duration_ms: duration_ms
              })

              Phoenix.PubSub.broadcast(
                OptimalSystemAgent.PubSub,
                "osa:session:#{parent_id}",
                {:osa_event,
                 %{
                   type: :background_agent_failed,
                   agent_id: subagent_id,
                   display_name: display_name,
                   role: role,
                   error: inspect(reason),
                   duration_ms: duration_ms,
                   elapsed_ms: elapsed_ms,
                   usage: usage,
                   cost_usd: cost_usd,
                   output_file: output_file
                 }}
              )

              emit_agent_finished(parent_id, subagent_id, display_name, duration_ms, nil, :failed)
          end
        end
      end)

    watch_runner(parent_id, subagent_id, display_name, role, runner_pid)

    {:ok, subagent_id}
  end

  # ── The runner's death is a FACT, not an absence of signal ───────────────
  #
  # `run_background/2` discarded the pid `Task.Supervisor.start_child/2` handed
  # back, so nothing anywhere was joined to, linked to, or monitoring the
  # process that runs a background subagent. The `try/rescue/catch` around
  # `run_subagent/1` covers faults raised INSIDE the task and nothing else: a
  # `Process.exit(pid, :kill)`, a supervisor shutdown, an OOM kill or any other
  # exit signal delivered from outside kills the task between its `START` and
  # the terminal broadcast at the bottom of its body. When that happened:
  #
  #   * no `:background_agent_completed` / `_failed` was ever broadcast, so the
  #     parent's `BackgroundNotifier` waited for a result that could not come;
  #   * the RunStore row stayed `:running` until the next BOOT, when
  #     `reconcile_stale_running/1` finally cleaned it up;
  #   * the transcript showed a `START` and then nothing — no `STOP`, ever;
  #   * and the TUI, having no signal to go on, could only say what it says when
  #     it has no signal: "no recent signal".
  #
  # A monitor converts that silence into an event. `Process.monitor/1` fires
  # immediately with `:noproc` if the target is already dead, so this needs no
  # timeout and cannot itself wedge — which is the whole point: the state
  # resolves because something OBSERVED it, not because a clock ran out.
  #
  # It never terminates anything. It only reports, and only when the task died
  # without leaving a terminal row behind — a task that completed normally has
  # already written its own outcome and this exits silently.
  @doc false
  @spec watch_runner(String.t(), String.t(), String.t(), String.t(), pid() | any()) :: :ok
  def watch_runner(parent_id, subagent_id, display_name, role, runner_pid)
      when is_pid(runner_pid) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      ref = Process.monitor(runner_pid)

      receive do
        {:DOWN, ^ref, :process, _pid, reason} ->
          if operator_controlled?(subagent_id) do
            :ok
          else
            # A clean exit means the task ran to the end of its body and has
            # already broadcast its own terminal event.
            if reason != :normal do
              report_runner_death(parent_id, subagent_id, display_name, role, reason)
            else
              # Even a `:normal` exit is only trustworthy if a terminal row
              # exists. A task killed while `:brutal_kill`-shutting-down its
              # supervisor can report `:normal`; the row is the evidence.
              case RunStore.get(subagent_id) do
                %{status: :running} ->
                  report_runner_death(parent_id, subagent_id, display_name, role, :normal)

                _ ->
                  :ok
              end
            end
          end
      end
    end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def watch_runner(_parent_id, _subagent_id, _display_name, _role, _pid), do: :ok

  defp report_runner_death(parent_id, subagent_id, display_name, role, reason) do
    # Re-check under the monitor's own ordering: the task may have broadcast its
    # result microseconds before dying, in which case there is nothing to report
    # and reporting anyway would fabricate a failure for a run that succeeded.
    case RunStore.get(subagent_id) do
      %{status: :running} ->
        Logger.error(
          "[Orchestrator] Background subagent #{subagent_id} runner died without " <>
            "recording an outcome (reason: #{inspect(reason)}) — reporting it as failed " <>
            "so the parent is not left waiting on a process that no longer exists"
        )

        RunStore.complete(subagent_id, %{
          agent_id: subagent_id,
          status: :failed,
          summary: "background agent runner died: #{inspect(reason)}",
          duration_ms: nil
        })

        error = "runner process died without reporting a result (#{inspect(reason)})"

        payload = %{
          event: :background_agent_failed,
          session_id: parent_id,
          agent_id: subagent_id,
          display_name: display_name,
          role: role,
          error: error,
          duration_ms: nil
        }

        Bus.emit(:system_event, payload)

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{parent_id}",
          {:osa_event,
           payload
           |> Map.delete(:event)
           |> Map.merge(%{
             type: :background_agent_failed,
             output_file: RunStore.transcript_path_for(subagent_id)
           })}
        )

        emit_agent_finished(parent_id, subagent_id, display_name, nil, nil, :failed)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Resume a previously-run subagent with a new message, restoring its FULL
  transcript (CC `resumeAgent` parity — SendMessage-style continue).

  The child's saved message history (persisted by `execute_and_collect` before
  the Loop terminates) is replayed as the resumed agent's initial conversation
  with system messages and unresolved tool_uses filtered out, and its worktree
  path is restored when the directory still exists. The run restarts in the
  background under the ORIGINAL agent id, so the RunStore row, transcript file
  and @handle stay stable. Pre-WS7 runs (no saved messages) fall back to
  re-seeding the original task plus a transcript tail.
  """
  @spec resume_subagent(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resume_subagent(agent_id, message) when is_binary(agent_id) and is_binary(message) do
    # Fall back to the on-disk ETF snapshot when the ETS index has no row (e.g.
    # after a node restart before rehydrate, or a pruned terminal row) so resume
    # still works as long as <id>.md.messages.etf exists.
    run = RunStore.get(agent_id) || rehydrate_run(agent_id)

    cond do
      is_nil(run) ->
        {:error, "No run found for #{agent_id}"}

      run.status == :running and
          Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != [] ->
        {:error, "Agent #{agent_id} is still running — message it after it finishes"}

      true ->
        {transcript, meta} =
          case RunStore.load_messages(agent_id) do
            {:ok, messages, meta} ->
              filtered =
                messages
                |> Enum.reject(fn m ->
                  (Map.get(m, :role) || Map.get(m, "role")) == "system"
                end)
                |> filter_unresolved_tool_uses()

              {filtered, meta}

            _ ->
              {[], %{}}
          end

        working_dir =
          case Map.get(meta, :worktree_path) do
            path when is_binary(path) -> if File.dir?(path), do: path, else: nil
            _ -> nil
          end

        task =
          if transcript == [] do
            # Pre-WS7 run — legacy re-seed with the original task + transcript
            # tail for continuity (better than a cold start, worse than replay).
            prior =
              case RunStore.transcript(agent_id) do
                {:ok, content} -> content |> String.slice(-2000, 2000) |> to_string()
                _ -> "(no prior transcript available)"
              end

            run.task <>
              "\n\n[Resuming a previous run of this task. Prior progress:]\n" <>
              prior <> "\n\n[New instruction:]\n" <> message
          else
            message
          end

        control = ExecutionControl.get(agent_id) || %{}

        config =
          %{
            task: task,
            role: run.role,
            agent_id: agent_id,
            fork_messages: transcript,
            working_dir: working_dir,
            provider: Map.get(control, :provider),
            model: Map.get(control, :model),
            model_reason: Map.get(control, :model_reason),
            model_requirements: Map.get(control, :model_requirements)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        ExecutionControl.increment(agent_id, :retry_count)

        ExecutionControl.progress(agent_id, %{
          status: :running,
          recovery_state: "resumed",
          last_recovery_instruction: message
        })

        run_background(run.parent_session_id, config)
    end
  end

  # Reconstruct a minimal run row from the persisted ETF snapshot when the ETS
  # index has no live row for this agent (restart / pruned). Enough for
  # resume_subagent to proceed; full stats aren't needed to replay context.
  defp rehydrate_run(agent_id) do
    case RunStore.load_messages(agent_id) do
      {:ok, _messages, meta} when is_map(meta) ->
        %{
          agent_id: agent_id,
          parent_session_id: Map.get(meta, :parent_session_id) || "unknown",
          role: Map.get(meta, :role) || "agent",
          task: Map.get(meta, :task) || "",
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now(),
          duration_ms: nil,
          tool_count: 0,
          tokens_used: 0,
          recent_actions: [],
          result: nil,
          transcript_path: RunStore.transcript_path_for(agent_id)
        }

      _ ->
        nil
    end
  end

  @doc false
  # Drop tool-call/result pairs that never resolved (CC filterUnresolvedToolUses):
  # assistant tool_calls with no matching tool result are stripped (the message is
  # dropped entirely when it has no text), and orphan tool-result messages are
  # removed. Public only for tests.
  def filter_unresolved_tool_uses(messages) when is_list(messages) do
    resolved_ids =
      messages
      |> Enum.map(fn m -> Map.get(m, :tool_call_id) || Map.get(m, "tool_call_id") end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    called_ids =
      messages
      |> Enum.flat_map(fn m -> List.wrap(Map.get(m, :tool_calls) || Map.get(m, "tool_calls")) end)
      |> Enum.map(fn tc -> Map.get(tc, :id) || Map.get(tc, "id") end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    messages
    |> Enum.map(fn m ->
      case List.wrap(Map.get(m, :tool_calls) || Map.get(m, "tool_calls")) do
        [] ->
          m

        tcs ->
          kept =
            Enum.filter(tcs, fn tc ->
              MapSet.member?(resolved_ids, Map.get(tc, :id) || Map.get(tc, "id"))
            end)

          if kept == [] and blank_content?(m), do: nil, else: put_tool_calls(m, kept)
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn m ->
      tcid = Map.get(m, :tool_call_id) || Map.get(m, "tool_call_id")
      is_binary(tcid) and not MapSet.member?(called_ids, tcid)
    end)
  end

  defp blank_content?(m) do
    case Map.get(m, :content) || Map.get(m, "content") do
      c when is_binary(c) -> String.trim(c) == ""
      nil -> true
      _ -> false
    end
  end

  defp put_tool_calls(m, kept) do
    cond do
      Map.has_key?(m, :tool_calls) -> Map.put(m, :tool_calls, kept)
      Map.has_key?(m, "tool_calls") -> Map.put(m, "tool_calls", kept)
      true -> m
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency cap (delegate path)
  # ---------------------------------------------------------------------------

  @doc """
  Concurrency ceiling for the DELEGATE path — foreground fan-out via
  `run_parallel/3` and background spawns via `run_background/2`.

  Deliberately the SAME `:max_fleet_agents` knob `Agent.Fleet` enforces: an
  operator raising their concurrency budget means one thing, not two. Before
  this existed the cap applied only to `fleet`, while `delegate` — the tool the
  model actually reaches for — was unbounded.

  Public + `@doc false` so the cap is directly assertable in tests.
  """
  @spec delegate_concurrency_cap() :: pos_integer()
  def delegate_concurrency_cap do
    max(OptimalSystemAgent.Agent.Fleet.max_fleet_agents(), 1)
  rescue
    _ -> 16
  end

  @doc """
  Number of subagent runs currently counted as live against the cap.

  Reads RunStore's `:running` rows — the same source `GET /runs` reports — so
  "how many agents are running" means one thing across the product.
  """
  @spec live_agent_count() :: non_neg_integer()
  def live_agent_count do
    RunStore.list(limit: 100_000)
    |> Enum.count(fn run ->
      # `:queued` rows are registered at DISPATCH so that every lookup path
      # (`task_wait`, `task_output`, `task_stop`, the stall watcher) can see an
      # agent that exists but has not been admitted yet. They must not count
      # against the cap they are queued behind, or the queue would deadlock on
      # itself the moment the cap filled.
      Map.get(run, :status) == :running and Map.get(run, :phase) != :queued
    end)
  rescue
    _ -> 0
  end

  # Human detail for the `:queued` phase — what the agent is actually waiting
  # behind, in the operator's own units.
  defp queue_detail do
    "#{live_agent_count()} of #{delegate_concurrency_cap()} slots busy"
  rescue
    _ -> "waiting for a concurrency slot"
  end

  # ── Dispatch-phase narration ────────────────────────────────────────────
  #
  # Measured on the dispatch path with a mock provider, a trivial task and a
  # temp-dir workspace — the best case this code has — the parent received
  # `background_agent_started` at 17ms, `orchestrator_agent_started` at 22ms,
  # and then NOTHING for 7.2 seconds until the child's first tool call. On a
  # real repo (worktree isolation copies the tree), with a real model's
  # time-to-first-token and a cold provider connection, that same gap is
  # minutes. It is the single largest silence in the system and it is entirely
  # normal — the agent is healthy and working the whole time.
  #
  # Nothing observed it, so nothing could report it, so the TUI fell back to the
  # only thing it could compute locally: 90 seconds without a frame, therefore
  # "state unknown · last signal 4m ago". That message was accurate about the
  # UI's ignorance and told the user nothing about the agent.
  #
  # Each transition now emits. The states are named for what the agent IS doing,
  # not for what we failed to hear:
  #
  #   :queued         — admitted to nothing yet; waiting behind the cap.
  #   :starting       — admitted; setting up (worktree, hooks, agent memory).
  #   :awaiting_model — the Loop is up and the first provider call is out.
  #   :working        — has run at least one tool (set by `RunStore.progress/3`).
  #
  # Logged at `info` and mirrored into telemetry: every defect found in this
  # area was invisible because the code that knew never said anything.
  # How long this run has existed, by the BACKEND's clock, in milliseconds.
  #
  # Every frame that describes a running subagent carries this, because the only
  # start the TUI otherwise had was `Instant::now()` stamped when its own panel
  # first heard of the agent — a clock local to that process, restamped on every
  # `agent_started`. A reconnect, a replay, or a panel opened after work began
  # rebased elapsed to zero while the tool count stayed real, and the panel
  # reported "17s · 99 tools": two true numbers from two different clocks.
  #
  # Sent as an AGE rather than a start timestamp on purpose: an age is immune to
  # clock skew between the backend and whatever machine the TUI runs on, and the
  # client can recover an anchor exactly (`Instant::now() - elapsed_ms`).
  #
  # `nil` when there is no run row (a foreground/fleet path that never registered
  # one). Absent is not zero — a client must keep its own anchor rather than
  # reset to "just started".
  @doc false
  @spec run_elapsed_ms(String.t()) :: non_neg_integer() | nil
  def run_elapsed_ms(agent_id) when is_binary(agent_id) do
    case RunStore.get(agent_id) do
      %{started_at: %DateTime{} = t} ->
        max(DateTime.diff(DateTime.utc_now(), t, :millisecond), 0)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def run_elapsed_ms(_), do: nil

  @doc false
  @spec emit_phase(String.t(), String.t(), String.t(), atom(), String.t()) :: :ok
  def emit_phase(parent_id, subagent_id, display_name, phase, detail) do
    RunStore.set_phase(subagent_id, phase, detail)

    Logger.info(
      "[Orchestrator] #{subagent_id} phase=#{phase}" <>
        if(detail == "", do: "", else: " (#{detail})")
    )

    :telemetry.execute(
      [:osa, :subagent, :phase],
      %{count: 1},
      %{agent_id: subagent_id, parent_session_id: parent_id, phase: phase, detail: detail}
    )

    payload = %{
      agent_id: subagent_id,
      # `agent_name` is the key every `orchestrator_agent_*` frame uses to find
      # its roster row; carrying both means one frame serves both lookups.
      agent_name: subagent_id,
      display_name: display_name,
      phase: to_string(phase),
      detail: detail,
      elapsed_ms: run_elapsed_ms(subagent_id)
    }

    emit_event(parent_id, Map.put(payload, :event, "background_agent_phase"))

    Bus.emit(
      :system_event,
      payload
      |> Map.put(:event, :background_agent_phase)
      |> Map.put(:session_id, parent_id)
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec background_slot_available?() :: boolean()
  def background_slot_available?, do: live_agent_count() < delegate_concurrency_cap()

  # Block until a slot frees up, or until the admission wait budget expires.
  #
  # The budget exists so a leaked/stuck `:running` row can never permanently
  # wedge every future background spawn — the cap is a throttle, not a lock.
  # On expiry we proceed anyway and log, which is the same trade Fleet makes.
  # The count is a soft cap: two admissions can race past the same check, so
  # brief overshoot by a few agents is possible. That is a throttle behaving
  # like a throttle, and is categorically different from the previous behaviour
  # of no ceiling at all.
  defp await_background_slot(subagent_id) do
    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:optimal_system_agent, :background_admission_timeout_ms, 3_600_000)

    do_await_background_slot(subagent_id, deadline, false)
  end

  defp do_await_background_slot(subagent_id, deadline, logged?) do
    cond do
      background_slot_available?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "[Orchestrator] #{subagent_id} waited out the background admission budget " <>
            "(cap: #{delegate_concurrency_cap()}) — starting anyway"
        )

        :ok

      true ->
        unless logged? do
          Logger.info(
            "[Orchestrator] #{subagent_id} queued — #{live_agent_count()} agent(s) already " <>
              "running at the :max_fleet_agents cap of #{delegate_concurrency_cap()}"
          )
        end

        Process.sleep(
          Application.get_env(:optimal_system_agent, :background_admission_poll_ms, 250)
        )

        do_await_background_slot(subagent_id, deadline, true)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp execute_and_collect(
         subagent_id,
         task,
         parent_id,
         role,
         _max_iter,
         worktree_info,
         opts \\ []
       ) do
    display_name = Keyword.get(opts, :display_name) || role
    batch_id = Keyword.get(opts, :batch_id)
    resumed_from = Keyword.get(opts, :resumed_from)
    start_time = System.monotonic_time(:millisecond)

    # A real, finite, configurable join timeout for THIS specific
    # `Loop.process_message` call — passed explicitly as `opts[:timeout]`
    # rather than relying on `Loop.process_message/3`'s own
    # `:agent_turn_timeout_ms` default (which stays `:infinity` on purpose
    # for direct top-level user turns; changing that global default here
    # would regress legitimate hours-long interactive sessions). This is the
    # D1 fix: the foreground `delegate` path (dispatch_foreground ->
    # run_subagent -> here) previously had NO bound at all.
    timeout_ms =
      Keyword.get(opts, :timeout_ms) ||
        Application.get_env(
          :optimal_system_agent,
          :subagent_join_timeout_ms,
          @default_subagent_timeout_ms
        )

    result =
      try do
        Loop.process_message(subagent_id, task, timeout: timeout_ms)
      rescue
        e ->
          Logger.error("[Orchestrator] Subagent #{subagent_id} crashed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      catch
        :exit, {:timeout, _} ->
          Logger.warning(
            "[Orchestrator] Subagent #{subagent_id} timed out after #{timeout_ms}ms — terminating"
          )

          # The GenServer.call timing out does NOT stop the callee — the child
          # Loop keeps running (and burning tokens) with no one left waiting
          # on it. Force-terminate it now instead of leaking it (mirrors
          # run_parallel's Task.shutdown(:brutal_kill) on its own timeout).
          force_terminate_orphan(subagent_id)
          {:error, :timeout}

        :exit, {reason, {GenServer, :call, _}}
        when reason in [:shutdown, :killed, :noproc] ->
          # The child's GenServer was deliberately terminated mid-call — most
          # likely `Loop.cancel/1` force-terminating it (explicit user
          # cancel/Esc reaching a blocked child, loop.ex's
          # `force_terminate_subagent/1`, which exits its target with
          # `:shutdown`/escalates to `:killed`) or it was already gone
          # (`:noproc`) by the time we called. Either way this is a
          # cancellation, not an organic crash.
          Logger.warning(
            "[Orchestrator] Subagent #{subagent_id} was terminated (cancelled) while running"
          )

          {:error, :cancelled}

        :exit, reason ->
          Logger.error("[Orchestrator] Subagent #{subagent_id} exited: #{inspect(reason)}")
          {:error, {:crashed, reason}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Get metadata from the subagent for the completion event. Read the child's
    # transcript once (it is idle-but-alive at this point) to derive real
    # commands_run and a natural-language synthesis of what it did.
    {tool_uses, tokens_used} = get_subagent_stats(subagent_id)
    files_changed = changed_files(worktree_info)
    child_messages = safe_get_messages(subagent_id)
    commands_run = extract_commands_run(child_messages)

    # WS7 — snapshot the child's FULL message history + resume metadata BEFORE
    # the Loop is terminated, so resume_subagent/2 can restore complete context
    # (CC recordSidechainTranscript/writeAgentMetadata parity).
    RunStore.save_messages(subagent_id, child_messages, %{
      agent_id: subagent_id,
      parent_session_id: parent_id,
      task: task,
      role: role,
      worktree_path: worktree_info && worktree_info.path,
      resumed_from: resumed_from
    })

    case result do
      {:ok, response} when is_binary(response) ->
        structured =
          structured_result(%{
            agent_id: subagent_id,
            parent_session_id: parent_id,
            role: role,
            status: :completed,
            summary: response,
            files_changed: files_changed,
            commands_run: commands_run,
            tool_count: tool_uses,
            tokens_used: tokens_used,
            duration_ms: duration_ms,
            worktree: worktree_info,
            resumed_from: resumed_from
          })

        RunStore.complete(subagent_id, structured)

        Logger.info(
          "[Orchestrator] Subagent #{subagent_id} completed in #{duration_ms}ms (#{tool_uses} tools, #{tokens_used} tokens)"
        )

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          display_name: display_name,
          status: "completed",
          tool_uses: tool_uses,
          tokens_used: tokens_used,
          duration_ms: duration_ms,
          batch_id: batch_id,
          summary: completion_summary(structured),
          result: structured
        })

        emit_agent_finished(
          parent_id,
          subagent_id,
          display_name,
          duration_ms,
          batch_id,
          :completed
        )

        {:ok,
         structured
         |> ResultSummarizer.summarize(child_messages)
         |> append_cost_note(subagent_id)}

      {:error, reason} ->
        structured =
          failure_result(subagent_id, parent_id, role, reason,
            duration_ms: duration_ms,
            files_changed: files_changed,
            commands_run: commands_run,
            salvaged: salvage_text(child_messages),
            tool_count: tool_uses,
            tokens_used: tokens_used,
            worktree: worktree_info,
            resumed_from: resumed_from
          )

        RunStore.complete(subagent_id, structured)

        # A deliberate user cancel is NOT a failure. RunStore models `:cancelled`
        # first-class and LATCHES terminal states, so the durable status must be
        # stamped correctly here (see `terminal_status/1`), and the wire status
        # must agree with it — the TUI agents panel already understands
        # "cancelled" (components/agents/mod.rs).
        wire_status = to_string(terminal_status(reason))

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          display_name: display_name,
          status: wire_status,
          error: to_string(reason),
          summary: completion_summary(to_string(reason)),
          tool_uses: tool_uses,
          tokens_used: tokens_used,
          duration_ms: duration_ms,
          batch_id: batch_id
        })

        emit_agent_finished(
          parent_id,
          subagent_id,
          display_name,
          duration_ms,
          batch_id,
          terminal_status(reason)
        )

        {:error, reason}

      other ->
        structured =
          structured_result(%{
            agent_id: subagent_id,
            parent_session_id: parent_id,
            role: role,
            status: :completed,
            summary: inspect(other),
            files_changed: files_changed,
            commands_run: commands_run,
            tool_count: tool_uses,
            tokens_used: tokens_used,
            duration_ms: duration_ms,
            worktree: worktree_info,
            resumed_from: resumed_from
          })

        RunStore.complete(subagent_id, structured)

        # Unexpected return — treat as success with inspect
        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          display_name: display_name,
          status: "completed",
          tool_uses: tool_uses,
          tokens_used: tokens_used,
          duration_ms: duration_ms,
          batch_id: batch_id,
          summary: completion_summary(structured)
        })

        emit_agent_finished(
          parent_id,
          subagent_id,
          display_name,
          duration_ms,
          batch_id,
          :completed
        )

        {:ok,
         structured
         |> ResultSummarizer.summarize(child_messages)
         |> append_cost_note(subagent_id)}
    end
  end

  # Shared-contract "teammate finished" event on the session topic. The TUI
  # renders `⏺ Teammate @<display_name> finished · <duration>`. Distinct from
  # the panel-oriented orchestrator_agent_completed: this carries exactly the
  # fields the chat-line parser needs.
  defp emit_agent_finished(parent_id, agent_id, display_name, duration_ms, batch_id, status) do
    emit_event(parent_id, %{
      event: "agent_finished",
      agent_id: agent_id,
      display_name: display_name,
      duration_ms: duration_ms,
      batch_id: batch_id,
      status: to_string(status)
    })
  end

  # Read the subagent's message history for result shaping. Best-effort — the
  # child may have already terminated; returns [] on any failure.
  defp safe_get_messages(subagent_id) do
    Loop.get_messages(subagent_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Extract the real shell commands a subagent ran from its transcript, in
  # order. Replaces the previously hardcoded `commands_run: []`.
  defp extract_commands_run(messages) when is_list(messages) do
    messages
    |> Enum.filter(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) and tcs != [] -> true
      _ -> false
    end)
    |> Enum.flat_map(fn msg -> msg.tool_calls end)
    |> Enum.filter(fn tc -> to_string(Map.get(tc, :name, "")) in ~w(shell_execute bash git) end)
    |> Enum.map(fn tc ->
      args = Map.get(tc, :arguments, %{})
      Map.get(args, "command") || Map.get(args, "cmd") || Map.get(args, "args") || ""
    end)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_commands_run(_), do: []

  defp get_subagent_stats(subagent_id) do
    # Get actual metadata from the Loop GenServer
    meta = Loop.get_metadata(subagent_id)
    tool_count = length(List.wrap(Map.get(meta, :tools_used, [])))

    # Get actual token count from Loop state snapshot. When the child Loop is
    # already gone (common — stats are read right after it terminates), fall back
    # to the last token count persisted in RunStore rather than fabricating
    # tool_count * 500, which silently corrupted usage totals.
    actual_tokens =
      try do
        case Loop.get_state(subagent_id) do
          {:ok, %{tokens_used: t}} when is_integer(t) and t > 0 -> t
          _ -> last_known_tokens(subagent_id)
        end
      rescue
        _ -> last_known_tokens(subagent_id)
      catch
        :exit, _ -> last_known_tokens(subagent_id)
      end

    {tool_count, actual_tokens}
  rescue
    _ -> {0, 0}
  end

  # Last token count persisted for this subagent; 0 when unknown (never fabricate).
  defp last_known_tokens(subagent_id) do
    case RunStore.get(subagent_id) do
      %{tokens_used: t} when is_integer(t) and t > 0 -> t
      _ -> 0
    end
  end

  # ── Phase-aware stall detection (background runs) ─────────────────────
  #
  # `run_background/2` returns immediately and then has NO visibility into
  # whether the child is working or wedged. The only backstop anywhere is the
  # 2h join timeout — and a background run is never joined, so in practice a
  # stuck background subagent was silent until the parent gave up on it. That
  # is the worst failure shape for a long task: the parent waits on a teammate
  # that stopped making progress an hour ago.
  #
  # The watcher polls the child's RunStore row for a PROGRESS FINGERPRINT
  # (tool_count + tokens + newest action). Unchanged fingerprint = no progress.
  # It is phase-aware because "no tools yet" and "tools then nothing" are
  # different failures with different normal durations:
  #
  #   :starting — spawned, zero tools so far. Model/provider setup and the
  #               first completion legitimately take minutes, so the threshold
  #               is long enough not to cry wolf on a slow first token.
  #   :working  — has run at least one tool. A gap here means a hung tool or a
  #               provider that stopped responding mid-run; a much shorter
  #               threshold is appropriate.
  #
  # It only OBSERVES: it emits `:background_agent_stalled` and stops. It never
  # kills the child — a long-running-but-alive teammate must not be reaped by a
  # heuristic, and the existing join timeout remains the only hard stop.
  # It exits as soon as the run reaches a terminal status or its row disappears.
  @stall_poll_interval_ms 30_000
  @stall_threshold_starting_ms 5 * 60 * 1000
  @stall_threshold_working_ms 15 * 60 * 1000

  defp stall_poll_interval_ms,
    do:
      Application.get_env(:optimal_system_agent, :stall_poll_interval_ms, @stall_poll_interval_ms)

  defp stall_threshold_ms(:starting),
    do:
      Application.get_env(
        :optimal_system_agent,
        :stall_threshold_starting_ms,
        @stall_threshold_starting_ms
      )

  defp stall_threshold_ms(:working),
    do:
      Application.get_env(
        :optimal_system_agent,
        :stall_threshold_working_ms,
        @stall_threshold_working_ms
      )

  @doc false
  @spec start_stall_watcher(String.t(), String.t(), String.t(), String.t()) :: :ok
  def start_stall_watcher(parent_id, subagent_id, display_name, role) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      watch_for_stall(parent_id, subagent_id, display_name, role, nil, progressing())
    end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Backoff for repeat stall reports.
  #
  # Every report costs the parent a turn: it wakes up, reads the alert, and
  # decides. A truly wedged child used to generate one of those every threshold
  # period forever — the transcript that prompted this had the same "no progress
  # for 15 minutes" line five times over, each one interrupting the parent with
  # information it already had. The observation still continues (a stall that
  # ends must be noticed), but the *reporting* rate decays: threshold, 2x,
  # 4x, ... capped so the parent is never told more than once an hour about a
  # stall it has already been told about.
  @max_stall_report_gap_ms 60 * 60 * 1000

  defp stall_report_gap_ms(phase, reports) do
    base = stall_threshold_ms(phase)
    # Cap the shift before computing so a long-lived watcher cannot build a
    # bignum here.
    scale = Bitwise.bsl(1, min(reports, 16))
    min(base * scale, max(@max_stall_report_gap_ms, base))
  end

  # `stall` carries the watcher's own state, separate from the run's:
  #
  #   :last_change_at - when the run's fingerprint last moved OR when we last
  #                     reported. This is the report clock only.
  #   :since          - the FIRST moment progress stopped, nil while progressing.
  #                     Reports are measured from here so they ESCALATE; measuring
  #                     from :last_change_at made every report say the same
  #                     "15 minutes" no matter how long the stall had really
  #                     lasted, so an operator could not tell a fresh stall from
  #                     a two-hour-old one.
  #   :reports        - how many times we have already reported THIS stall, which
  #                     drives the backoff above. Reset whenever work lands.
  defp watch_for_stall(parent_id, subagent_id, display_name, role, last_print, stall) do
    Process.sleep(stall_poll_interval_ms())

    case RunStore.get(subagent_id) do
      # A queued agent is not stalled — it has been admitted to nothing yet, and
      # its fingerprint cannot change until it starts. Keep watching, and reset
      # the change clock so the queue wait is never counted against the stall
      # threshold. (Before the row was created at dispatch this clause was
      # reached as `nil` and fell into the catch-all below, killing the watcher
      # on its first poll and leaving the agent unwatched for the rest of its
      # life — the one component that could have explained the silence was the
      # first thing the silence took out.)
      %{status: :running, phase: :queued} ->
        watch_for_stall(parent_id, subagent_id, display_name, role, last_print, progressing())

      %{status: :running} = run ->
        print = progress_fingerprint(run)
        phase = if run.tool_count > 0, do: :working, else: :starting

        cond do
          print != last_print ->
            watch_for_stall(parent_id, subagent_id, display_name, role, print, progressing())

          now_ms() - stall.last_change_at >= stall_report_gap_ms(phase, stall.reports) ->
            since = stall.since || stall.last_change_at

            emit_stall(
              parent_id,
              subagent_id,
              display_name,
              role,
              phase,
              now_ms() - since,
              run
            )

            # Keep watching after reporting.
            #
            # The watcher used to RETURN here, so a run got at most one stall
            # report in its entire lifetime and was then unobserved forever
            # after — including a run that recovered and stalled again, and
            # including one that never came back at all. Continuing costs one
            # poll every 30s and means the observation keeps up with reality.
            watch_for_stall(parent_id, subagent_id, display_name, role, print, %{
              last_change_at: now_ms(),
              since: since,
              reports: stall.reports + 1
            })

          true ->
            watch_for_stall(parent_id, subagent_id, display_name, role, print, %{
              stall
              | since: stall.since || stall.last_change_at
            })
        end

      # Terminal, or the row was pruned: nothing left to watch.
      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Fresh watcher state: work just landed (or is yet to land), so nothing is
  # stalled and any earlier stall's backoff is forgotten.
  defp progressing, do: %{last_change_at: now_ms(), since: nil, reports: 0}

  defp progress_fingerprint(run) do
    {Map.get(run, :tool_count, 0), Map.get(run, :tokens_used, 0),
     run |> Map.get(:recent_actions, []) |> List.first()}
  end

  defp emit_stall(parent_id, subagent_id, display_name, role, phase, stalled_ms, run) do
    minutes = div(stalled_ms, 60_000)

    detail =
      case phase do
        :starting ->
          "it has not run a single tool since it started — most likely a provider/model " <>
            "setup failure. Next step: check it with task_output, and re-dispatch with a " <>
            "different model or a narrower task if it is wedged."

        :working ->
          "it ran #{run.tool_count} tool(s) and then went quiet — most likely a hung tool " <>
            "or a stalled provider call. Next step: inspect its transcript with task_output, " <>
            "and stop it with task_stop if it is not recoverable."
      end

    Logger.warning(
      "[Orchestrator] Background subagent #{subagent_id} appears stalled in :#{phase} " <>
        "for #{minutes}m"
    )

    ExecutionControl.progress(subagent_id, %{
      status: :stalled,
      current_tool: run |> Map.get(:recent_actions, []) |> List.first(),
      tool_count: Map.get(run, :tool_count, 0),
      tokens_used: Map.get(run, :tokens_used, 0),
      recovery_state: "inspect_retry_cancel_or_reassign",
      stalled_ms: stalled_ms
    })

    payload = %{
      event: :background_agent_stalled,
      session_id: parent_id,
      agent_id: subagent_id,
      display_name: display_name,
      role: role,
      phase: phase,
      stalled_ms: stalled_ms,
      tool_count: run.tool_count,
      message:
        "Background agent @#{display_name} has made no progress for #{minutes} minutes: #{detail}"
    }

    Bus.emit(:system_event, payload)

    # Same dual-emit as the completed/failed events above, so the TUI and SSE
    # consumers see a stall on the session topic they already listen to.
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{parent_id}",
      {:osa_event, Map.put(payload, :type, :background_agent_stalled)}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── Per-delegation cost ───────────────────────────────────────────────
  #
  # The spend of every run is already accumulated per session and persisted by
  # `SessionPersistence` — `Accounting.tree_spend_usd/1` reads exactly this to
  # enforce `max_budget_usd`. The number existed; the model just never saw it.
  # A delegating agent that cannot see what a delegation cost cannot decide
  # whether to delegate again, so it either under-uses subagents or fans out
  # until a budget guard stops it.
  #
  # Appended to the summary the parent model reads, so budgeting is a fact in
  # context rather than a guess. Read-only and best-effort: a missing sidecar
  # returns 0.0 and the note is simply omitted.
  @doc """
  USD spend of a single completed run, read from its durable spend sidecar.

  Returns `0.0` when the run has no recorded spend (free/local provider, or a
  sidecar that was never written).
  """
  @spec run_cost_usd(String.t()) :: float()
  def run_cost_usd(agent_id) when is_binary(agent_id) do
    case OptimalSystemAgent.Agent.SessionPersistence.load_spend(agent_id) do
      %{cost_usd: c} when is_number(c) and c > 0 -> c * 1.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    :exit, _ -> 0.0
  end

  def run_cost_usd(_), do: 0.0

  @doc """
  Cost of a run for REPORTING, where "we never recorded a cost" and "it cost
  nothing" must not collapse into the same number.

  `run_cost_usd/1` answers with a float because its callers do arithmetic and
  string formatting on it. Event payloads need the other answer: `nil` when the
  spend record is absent, so the TUI can render `—` instead of asserting `$0.00`
  about a run whose price nobody measured.
  """
  @spec reported_cost_usd(String.t()) :: float() | nil
  def reported_cost_usd(agent_id) do
    case run_cost_usd(agent_id) do
      cost when is_number(cost) and cost > 0 -> cost * 1.0
      _ -> nil
    end
  end

  @doc """
  The `usage` map that rides a terminal background-agent broadcast.

  `duration_ms` is always known — it is measured here, not looked up. The two
  COUNTERS are not: they live on the run's `RunStore` row, and a run whose row
  was evicted, never written, or reaped by a crash has no counters at all.

  Those keys are therefore OMITTED rather than defaulted to `0`. The TUI decodes
  `usage.total_tokens` / `usage.tool_uses` as `Option<u32>` and applies them
  non-destructively (`Agents::agent_completed`), specifically so an absent
  number leaves the counters accumulated from progress events alone. Sending a
  literal `0` defeats that: it decodes as `Some(0)` — an assertion that the
  teammate used no tokens and ran no tools — and erases a real 40k/12 that the
  panel had already been told about, at the exact moment the user looks at it.

  Unmeasured and zero are different facts. Only one of them is ever true here.
  """
  @spec reported_usage(map() | nil, non_neg_integer()) :: map()
  def reported_usage(final_run, duration_ms) do
    %{duration_ms: duration_ms}
    |> put_if_number(:total_tokens, final_run && Map.get(final_run, :tokens_used))
    |> put_if_number(:tool_uses, final_run && Map.get(final_run, :tool_count))
  end

  defp put_if_number(map, key, value) when is_number(value), do: Map.put(map, key, value)
  defp put_if_number(map, _key, _value), do: map

  defp append_cost_note(summary, agent_id) when is_binary(summary) do
    case run_cost_usd(agent_id) do
      cost when cost > 0 ->
        summary <>
          "\n\nDelegation cost: $#{:erlang.float_to_binary(cost, decimals: 4)} " <>
          "(this subagent only). Factor it in before delegating again."

      _ ->
        summary
    end
  end

  defp append_cost_note(summary, _agent_id), do: summary

  defp structured_result(attrs) do
    agent_id = Map.fetch!(attrs, :agent_id)
    run = RunStore.get(agent_id)

    %{
      agent_id: agent_id,
      parent_session_id: Map.fetch!(attrs, :parent_session_id),
      role: Map.fetch!(attrs, :role),
      status: Map.fetch!(attrs, :status),
      summary: Map.get(attrs, :summary, ""),
      files_changed: Map.get(attrs, :files_changed, []),
      commands_run: Map.get(attrs, :commands_run, []),
      tool_count: Map.get(attrs, :tool_count, 0),
      tokens_used: Map.get(attrs, :tokens_used, 0),
      duration_ms: Map.get(attrs, :duration_ms, 0),
      errors: Map.get(attrs, :errors, []),
      next_actions: Map.get(attrs, :next_actions, []),
      transcript_path: (run && run.transcript_path) || "unavailable",
      worktree: Map.get(attrs, :worktree),
      # P6 peer-resume (sibling handoff) — surfaced in the structured result so
      # the parent orchestrator's summary/UI can show lineage when relevant.
      resumed_from: Map.get(attrs, :resumed_from)
    }
  end

  @doc """
  Structured result for a subagent that did NOT finish its task.

  The durable status is derived from the reason via `terminal_status/1`: a
  deliberate user cancel settles as `:cancelled`, everything else as `:failed`.
  Public + `@doc false` so the status/summary mapping is unit-testable without
  booting a full orchestrator run.
  """
  @doc false
  def failure_result(agent_id, parent_id, role, reason, opts \\ []) do
    status = terminal_status(reason)

    verb =
      case status do
        :cancelled -> "CANCELLED"
        _ -> "FAILED"
      end

    structured_result(%{
      agent_id: agent_id,
      parent_session_id: parent_id,
      role: role,
      status: status,
      summary:
        with_salvage(
          "Subagent #{role} #{verb}: #{failure_reason_text(reason)}",
          Keyword.get(opts, :salvaged)
        ),
      files_changed: Keyword.get(opts, :files_changed, []),
      commands_run: Keyword.get(opts, :commands_run, []),
      tool_count: Keyword.get(opts, :tool_count, 0),
      tokens_used: Keyword.get(opts, :tokens_used, 0),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      errors: [inspect(reason)],
      worktree: Keyword.get(opts, :worktree),
      resumed_from: Keyword.get(opts, :resumed_from)
    })
  end

  # A subagent that fails at the END of its work has still DONE the work, and
  # the parent needs to know that before it decides to re-dispatch. The case
  # that motivated this: a background agent built 67 pages, ran 157 passing
  # tests and reached zero type errors, then tripped a join timeout while
  # writing its final report — and the only thing the parent was told was
  # "failed after 7205022ms: :timeout". It had no way to learn that the task
  # was in fact complete, so the obvious next move was to redo all of it.
  defp with_salvage(summary, nil), do: summary
  defp with_salvage(summary, ""), do: summary

  defp with_salvage(summary, salvaged) when is_binary(salvaged) do
    summary <>
      "\n\nWork recorded before it stopped (recovered from the transcript, " <>
      "may be incomplete):\n" <> salvaged
  end

  defp with_salvage(summary, _), do: summary

  @salvage_limit 4_000

  @doc false
  @spec salvage_text([map()]) :: String.t() | nil
  def salvage_text(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "assistant", content: content} when is_binary(content) ->
        case String.trim(content) do
          "" -> nil
          text -> String.slice(text, 0, @salvage_limit)
        end

      _ ->
        nil
    end)
  end

  def salvage_text(_), do: nil

  @doc """
  Terminal `RunStore` status for a non-completion reason.

  `:cancelled` (an explicit user interrupt/Esc reaching the child, see
  `execute_and_collect/7`'s `:exit, :killed` handling) is a first-class RunStore
  status — persisting it as `:failed` durably mislabels deliberate user action
  as a fault. Every other reason (timeout, crash, already_started, ...) is a
  genuine failure.
  """
  @doc false
  @spec terminal_status(term()) :: :cancelled | :failed
  def terminal_status(:cancelled), do: :cancelled
  def terminal_status(_reason), do: :failed

  # Human-readable classification for a failed subagent — surfaced to the
  # parent model so it does not mistake a timeout/cancel/crash for real
  # completed work (D2). Known machine reasons get a clear sentence; anything
  # else falls back to `inspect/1`.
  defp failure_reason_text(:timeout),
    do: "the subagent did not finish within its join timeout and was terminated"

  defp failure_reason_text(:cancelled),
    do: "the subagent was cancelled (interrupt/Esc) and terminated before finishing"

  defp failure_reason_text({:crashed, reason}),
    do: "the subagent process crashed/exited: #{inspect(reason)}"

  defp failure_reason_text(reason), do: inspect(reason)

  # Longest compact `summary` shipped to the TUI agents panel. The full
  # structured result (which can be large) is NEVER sent on this field — only
  # this short, single-line preview rides the completion event.
  @summary_max 140

  # Best-effort compact one-line summary of a worker's final result (or error),
  # for the agents panel. Takes the first meaningful line, collapses interior
  # whitespace/newlines, and trims to `@summary_max` chars. Never raises: any
  # extraction failure yields "" so it can never break the completion emit.
  # Public only as a deterministic test seam (`@doc false`); not a stable API.
  @doc false
  def completion_summary(source) do
    source
    |> summary_source_text()
    |> first_meaningful_line()
    |> String.slice(0, @summary_max)
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  # Pull the worker's final assistant text out of whatever we were handed. A
  # structured result map carries it in `:summary`; a bare string is used as-is;
  # anything without an obvious text field falls back to a truncated inspect.
  defp summary_source_text(%{summary: s}) when is_binary(s), do: s
  defp summary_source_text(s) when is_binary(s), do: s
  defp summary_source_text(other), do: inspect(other)

  # First non-blank line with interior runs of whitespace (including embedded
  # newlines) collapsed to single spaces, so the panel always gets ONE clean line.
  defp first_meaningful_line(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> then(&Regex.replace(~r/\s+/, &1, " "))
    |> String.trim()
  end

  @doc """
  Repo-relative paths a subagent modified inside its worktree.

  Uses the NUL-separated `-z` porcelain format and delegates parsing to
  `OptimalSystemAgent.Agent.Fleet.parse_porcelain_z/1`, which is the single
  correct implementation of that format (it is public + `@doc false` there
  precisely so it can be shared/unit-tested; nothing in fleet.ex changes).

  Without `-z`, git QUOTES any path containing a space or a non-ASCII byte
  (`"my file.txt"`, `"caf\\303\\251.txt"`) and renders a rename as the single
  bogus field `old -> new` — so the previous
  `split("\\n") |> slice(3..-1)` here produced paths that do not exist on disk.

  Public + `@doc false` so the porcelain contract is testable against a real
  throwaway repo without booting an orchestrator run.
  """
  @doc false
  @spec changed_files(nil | map()) :: [binary()]
  def changed_files(nil), do: []

  def changed_files(%{path: path}) when is_binary(path) do
    # Guard on existence: cd-ing into a vanished worktree prints a noisy
    # `spawn: Could not cd` to stderr and there is nothing to diff anyway.
    if not File.dir?(path) do
      []
    else
      changed_files_git(path)
    end
  end

  def changed_files(_), do: []

  defp changed_files_git(path) do
    case OptimalSystemAgent.Git.cmd(["status", "--porcelain", "-z"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> OptimalSystemAgent.Agent.Fleet.parse_porcelain_z(output)
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Event forwarder — spawns a Task that listens for subagent tool_call
  # events and re-emits them as orchestrator_agent_progress on the parent channel.
  defp start_event_forwarder(subagent_id, parent_id, role) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      # Subscribe INSIDE this process — PubSub subscriptions are per-process
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{subagent_id}")
      forwarder_loop(subagent_id, parent_id, role, 0)
    end)
  end

  defp forwarder_loop(subagent_id, parent_id, role, tool_count) do
    receive do
      # Tool call START — update action line with what the tool is doing
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase, args: args}}
      when phase in ["start", :start] ->
        action = format_action(tool_name, args)
        RunStore.progress(subagent_id, action, tool_count)
        record_execution_progress(subagent_id, action, tool_count)

        emit_event(
          parent_id,
          Map.merge(
            %{
              event: "orchestrator_agent_progress",
              agent_name: subagent_id,
              current_action: action,
              tool_uses: tool_count,
              tokens_used: forwarder_tokens(subagent_id),
              recent_actions: recent_actions(subagent_id),
              # The backend's own clock for this run - see `run_elapsed_ms/1`. It
              # rides on every progress frame so a client that connected late, or
              # reconnected, learns the real age alongside the tool count instead of
              # pairing a real count with a freshly-zeroed local timer.
              elapsed_ms: run_elapsed_ms(subagent_id),
              description: ""
            },
            execution_event_fields(subagent_id)
          )
        )

        # The THIRD silence, and the one the brief names first: a tool that runs
        # for minutes (a build, a test suite, a large grep) emits nothing between
        # its start and its end. Without this the row's phase would still read
        # `awaiting_model` — set when the PREVIOUS tool finished — for the whole
        # time a tool was actually running, which is a confident wrong answer
        # rather than an honest unknown.
        #
        # "Running a tool", "waiting on the model" and "died" are three different
        # facts. All three are now stated as themselves.
        emit_phase(parent_id, subagent_id, role, :working, action)

        forwarder_loop(subagent_id, parent_id, role, tool_count)

      # Tool call END — increment counter
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase}}
      when phase in ["end", :end] ->
        new_count = tool_count + 1
        RunStore.progress(subagent_id, to_string(tool_name), new_count)
        record_execution_progress(subagent_id, nil, new_count)

        emit_event(
          parent_id,
          Map.merge(
            %{
              event: "orchestrator_agent_progress",
              agent_name: subagent_id,
              current_action: to_string(tool_name),
              tool_uses: new_count,
              tokens_used: forwarder_tokens(subagent_id),
              recent_actions: recent_actions(subagent_id),
              elapsed_ms: run_elapsed_ms(subagent_id),
              description: ""
            },
            execution_event_fields(subagent_id)
          )
        )

        # A finished tool means the agent has gone back to the model, and it
        # will emit nothing again until the NEXT tool starts.
        #
        # This is the same silence as the dispatch path, in the middle of a run:
        # the dispatch-phase fix labelled the gap before the first tool call, and
        # the timing probe immediately caught these — 5-second voids between
        # consecutive tools on a mock provider that answers instantly. On a real
        # model, with reasoning, that inter-tool gap is minutes, and it is the
        # "it appears alive but idle" the user described AFTER the slow start
        # resolved. It is also by far the most common state a long-running
        # subagent is in.
        emit_phase(parent_id, subagent_id, role, :awaiting_model, "thinking after #{tool_name}")

        forwarder_loop(subagent_id, parent_id, role, new_count)

      _ ->
        forwarder_loop(subagent_id, parent_id, role, tool_count)
    after
      # Idle safety net: stop forwarding after this many ms of SILENCE (no
      # events). The timer resets on every received event (the receive is
      # re-entered on each recursion), so a teammate that keeps streaming
      # progress stays alive indefinitely — a long-running (2h+) teammate no
      # longer loses its progress feed at 5 min. run_subagent also explicitly
      # stops the forwarder on completion, so this is purely a leak guard.
      Application.get_env(:optimal_system_agent, :forwarder_idle_timeout_ms, 1_800_000) -> :ok
    end
  end

  # Format a human-readable action string from tool name + args hint.
  # e.g., "file_read /home/user/..." or "web_search Rust TUI frameworks"
  defp format_action(tool_name, args) when is_binary(args) do
    hint = String.slice(args, 0, 60)

    if hint == "" or hint == "{}" do
      to_string(tool_name)
    else
      "#{tool_name}: #{hint}"
    end
  end

  defp format_action(tool_name, _), do: to_string(tool_name)

  # Real token count for progress events. The forwarder runs in its own Task
  # process (not the subagent's Loop), so a synchronous state read is safe and
  # cannot deadlock. Falls back to 0 rather than a fabricated tool_count*500.
  defp forwarder_tokens(subagent_id) do
    case Loop.get_state(subagent_id) do
      {:ok, %{tokens_used: t}} when is_integer(t) and t >= 0 -> t
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # Last-N tool actions (newest first) for the TUI trail — the FE renders the
  # last 3 with a "+N more tool uses" counter (CC MAX_PROGRESS_MESSAGES_TO_SHOW).
  defp recent_actions(subagent_id) do
    case RunStore.get(subagent_id) do
      %{recent_actions: actions} when is_list(actions) -> Enum.take(actions, 5)
      _ -> []
    end
  end

  defp stop_event_forwarder({:ok, pid}) when is_pid(pid) do
    Process.exit(pid, :normal)
  end

  defp stop_event_forwarder(_), do: :ok

  defp safely_terminate(pid) do
    try do
      DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # Terminate an orphaned subagent by id (looked up live) after OUR join to it
  # timed out — the GenServer.call timing out only stops us from waiting, it
  # never stops the callee, so a stuck child would otherwise keep running
  # (and burning tokens) unbounded with no one left to collect its result.
  defp force_terminate_orphan(subagent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, subagent_id) do
      [{pid, _}] -> safely_terminate(pid)
      _ -> :ok
    end
  end

  # Resolve the permission mode a spawning subagent should start in. An explicit
  # config value wins; otherwise inherit the parent's full-auto mode when the
  # parent is in overdrive/bypass (checked against the live loop first, then the
  # sticky store as a fallback); else nil, letting Loop.init use its default.
  defp inherited_permission_mode(config, parent_id) do
    cond do
      mode = Map.get(config, :permission_mode) -> mode
      parent_overdrive?(parent_id) -> :overdrive
      true -> nil
    end
  end

  defp parent_overdrive?(parent_id) when is_binary(parent_id) do
    live =
      case Loop.get_permission_mode(parent_id) do
        {:ok, m} -> m
        _ -> nil
      end

    live in [:overdrive, :bypass] or
      OptimalSystemAgent.Agent.PermissionMode.overdrive?(parent_id)
  end

  defp parent_overdrive?(_), do: false

  # P8 — config gate for child-worktree durable-ref snapshotting.
  #   config :optimal_system_agent, :subagent_worktree_snapshot, false
  #
  # ON by default (flipped). It was off because snapshotting commits dirty state
  # into the source repo's object store via a ref, which is "unwanted overhead".
  # That trade no longer holds:
  #
  #   * The cost is one commit on the CHILD's own branch plus one `update-ref`
  #     into a dedicated `refs/osa/subagent-snapshots/` namespace. The objects
  #     already live in the shared ODB, the parent branch is never touched, and
  #     the whole namespace is deletable with one `git for-each-ref | xargs`.
  #   * The benefit is the only durable record of a child's uncommitted work.
  #   * `finish_worktree/4` now gates destructive teardown on a snapshot having
  #     persisted. With the gate off by default, `discard: true` could never be
  #     honoured for a dirty tree — the enforcement would be vacuous and the
  #     option silently dead.
  #
  # Bounded overhead on one side, unrecoverable data loss on the other: default on.
  defp subagent_worktree_snapshot? do
    Application.get_env(:optimal_system_agent, :subagent_worktree_snapshot, true) == true
  end

  defp ensure_execution_control(agent_id, config, attrs) do
    if ExecutionControl.get(agent_id) do
      ExecutionControl.progress(agent_id, attrs)
    else
      ExecutionControl.start(
        agent_id,
        attrs
        |> Map.put(:model_reason, Map.get(config, :model_reason, "tier default"))
        |> Map.put(:model_requirements, Map.get(config, :model_requirements, ["tools"]))
        |> Map.put(:skill_reason, "subagent selects skills independently for its task")
      )
    end
  end

  defp record_execution_progress(agent_id, current_tool, tool_count) do
    skills = ActiveSkills.list(agent_id)
    control = ExecutionControl.get(agent_id) || %{}

    ExecutionControl.progress(agent_id, %{
      current_tool: current_tool,
      tool_count: tool_count,
      tokens_used: forwarder_tokens(agent_id),
      active_skills: skills,
      skill_reason:
        if(skills == [],
          do: "no skill selected yet",
          else: selected_skill_reason(skills, control)
        )
    })
  end

  defp record_terminal_skills(agent_id) do
    skills = ActiveSkills.list(agent_id)
    control = ExecutionControl.get(agent_id) || %{}

    ExecutionControl.progress(agent_id, %{
      active_skills: skills,
      skill_reason:
        if(skills == [],
          do: "no skill was selected for this task",
          else: selected_skill_reason(skills, control)
        )
    })
  end

  defp selected_skill_reason(skills, control) do
    task = control |> Map.get(:task, "delegated task") |> to_string() |> String.slice(0, 120)

    "subagent explicitly selected #{Enum.join(skills, ", ")} as relevant to: #{task}"
  end

  defp operator_controlled?(agent_id) do
    case ExecutionControl.get(agent_id) do
      %{status: status} ->
        to_string(status) in ["paused", "interrupted", "cancelled", "reassigned"]

      _ ->
        false
    end
  end

  defp execution_event_fields(agent_id) do
    case ExecutionControl.get(agent_id) do
      nil ->
        %{}

      control ->
        control
        |> Map.take([
          :active_skills,
          :model_reason,
          :skill_reason,
          :retry_count,
          :failure_count,
          :delivery_status
        ])
        |> Map.put(
          :available_controls,
          SubagentControl.available_controls(Map.get(control, :status, "unknown"))
        )
    end
  end

  defp emit_event(parent_session_id, event_data) do
    event_name = Map.get(event_data, :event, "unknown")

    # Format as system_event so the SSE loop extracts the sub-event type correctly.
    # SSE loop: %{type: :system_event, event: sub} -> to_string(sub)
    # TUI SSE parser matches on event types like "orchestrator_agent_started"
    full_event =
      event_data
      |> Map.put(:type, :system_event)
      |> Map.put(:event, event_name)
      |> Map.put(:session_id, parent_session_id)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{parent_session_id}",
      {:osa_event, full_event}
    )
  rescue
    _ -> :ok
  end

  defp next_subagent_number(_parent_id) do
    # Node-unique monotonic integer — no ETS ownership issues, no race conditions.
    System.unique_integer([:positive, :monotonic])
  end

  # Sanitize a caller-supplied teammate name into a filesystem/id-safe slug.
  # "@smoke-e2e" / "Smoke E2E" -> "smoke-e2e" / "smoke_e2e".
  defp sanitize_name(name) do
    name
    |> to_string()
    |> String.trim_leading("@")
    |> String.downcase()
    |> then(&Regex.replace(~r/[^a-z0-9_\-]+/, &1, "_"))
    |> String.slice(0, 48)
  end
end
