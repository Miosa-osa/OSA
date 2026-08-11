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

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.RunStore
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
  @default_subagent_timeout_ms 2 * 60 * 60 * 1000

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

        results =
          indexed_configs
          |> Enum.chunk_every(cap)
          |> Enum.flat_map(fn batch ->
            # Spawn one batch as async Tasks. Thread the stable batch_id
            # (team_id) and wave number into each config so run_subagent can
            # carry them onto lifecycle events — the TUI groups per-workstream
            # by batch_id and per-wave.
            tasks =
              Enum.map(batch, fn {config, original_idx} ->
                config =
                  config
                  |> Map.put(:parent_session_id, parent_id)
                  |> Map.put(:batch_id, team_id)
                  |> Map.put(:wave, wave_num)

                {original_idx,
                 Task.Supervisor.async_nolink(
                   OptimalSystemAgent.TaskSupervisor,
                   fn -> run_subagent(config) end
                 )}
              end)

            Enum.map(tasks, fn {original_idx, task} ->
              result =
                try do
                  Task.await(task, await_timeout)
                catch
                  :exit, {:timeout, _} ->
                    # Reap the async task instead of orphaning it — the underlying
                    # async_nolink Task keeps running run_subagent with no owner,
                    # burning tokens. brutal_kill stops the leak.
                    #
                    # Classified as a FAILURE (not laundered into {:ok, ...}) so
                    # `completed_count` below and `dispatch_fanout`'s reconcile
                    # gate never treat a timed-out workstream as real completed
                    # output — the parent model must not build on non-existent
                    # work (D2 — matches grok/opencode marking a failed subagent
                    # as failed, not success).
                    Task.shutdown(task, :brutal_kill)
                    {:error, :timeout}

                  :exit, reason ->
                    Task.shutdown(task, :brutal_kill)
                    {:error, {:crashed, reason}}
                end

              {original_idx, result}
            end)
          end)

        # Sort by original index to maintain order
        results
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, result} -> result end)
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
        # FastWorktree picks the fastest CoW tier the filesystem supports
        # (btrfs/reflink/copy) and falls back to a plain checkout. repo_dir is
        # the agent's resolved cwd (the user's project), NOT File.cwd! which
        # under `mix osa.serve` would be the OSA source tree.
        repo_dir = Map.get(config, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()

        case OptimalSystemAgent.Workspace.FastWorktree.create(subagent_id, repo_dir: repo_dir) do
          {:ok, info} ->
            Logger.info(
              "[Orchestrator] Worktree created for #{subagent_id} at #{info.path} " <>
                "(#{info.tier} tier)"
            )

            info

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
      delegation_depth: Map.get(config, :delegation_depth, 0) + 1
    ]

    # Start event forwarder BEFORE spawning the subagent so it catches
    # all tool_call events from the first iteration onward.
    forwarder = start_event_forwarder(subagent_id, parent_id, role)

    case DynamicSupervisor.start_child(
           OptimalSystemAgent.SessionSupervisor,
           {Loop, subagent_opts}
         ) do
      {:ok, pid} ->
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

        # P8 — durable-ref snapshot of a COMPLETED child's worktree, taken BEFORE
        # teardown so a discarded (or merged) worktree's final state is still
        # inspectable/resumable later via `git show <ref>` / `git worktree add
        # -b tmp <ref>`, without polluting the parent branch. Config-gated
        # (off by default) — this is a middle ground between "merge" and
        # "discard", not a replacement for either.
        snapshot_ref =
          if worktree_info && match?({:ok, _}, result) && subagent_worktree_snapshot?() do
            case OptimalSystemAgent.Workspace.FastWorktree.snapshot_ref(worktree_info.path,
                   id: subagent_id,
                   repo_dir: Map.get(worktree_info, :repo_dir)
                 ) do
              {:ok, ref} ->
                Logger.info("[Orchestrator] Worktree snapshot for #{subagent_id}: #{ref}")
                ref

              {:error, reason} ->
                Logger.warning(
                  "[Orchestrator] Worktree snapshot failed for #{subagent_id}: #{inspect(reason)}"
                )

                nil
            end
          end

        if snapshot_ref, do: RunStore.attach_worktree_snapshot(subagent_id, snapshot_ref)

        # Worktree cleanup — merge-back is explicit. Dirty worktrees are
        # preserved by default so the parent can inspect/apply changes.
        if worktree_info do
          merge = match?({:ok, _}, result) and Map.get(config, :merge_worktree, false)

          OptimalSystemAgent.Workspace.FastWorktree.teardown(worktree_info.path,
            merge: merge,
            discard: Map.get(config, :discard_worktree, false),
            repo_dir: Map.get(worktree_info, :repo_dir)
          )
        end

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

        if worktree_info do
          OptimalSystemAgent.Workspace.FastWorktree.teardown(worktree_info.path,
            merge: false,
            discard: Map.get(config, :discard_worktree, false),
            repo_dir: Map.get(worktree_info, :repo_dir)
          )
        end

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          status: "failed",
          error: inspect(reason),
          summary: completion_summary(inspect(reason)),
          tool_uses: 0,
          tokens_used: 0
        })

        {:error, reason}
    end
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
  @spec run_background(String.t(), map()) :: {:ok, String.t()}
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

    start_stall_watcher(parent_id, subagent_id, display_name, role)

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
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
      await_background_slot(subagent_id)

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

      # If the run raised before it could mark itself terminal, reap the RunStore
      # entry so GET /runs never sticks on :running.
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

      # WS7 — structured usage + output-file for the <task-notification> the
      # parent model receives (CC enqueueAgentNotification parity).
      final_run = RunStore.get(subagent_id)

      usage = %{
        total_tokens: (final_run && final_run.tokens_used) || 0,
        tool_uses: (final_run && final_run.tool_count) || 0,
        duration_ms: duration_ms
      }

      output_file = RunStore.transcript_path_for(subagent_id)

      # What this teammate actually cost. `run_cost_usd/1` is durable (it reads
      # the persisted spend record) and was already being appended to the
      # FOREGROUND delegate result — but a background run rode no event
      # carrying it, so the panel could only ever show a whole-task estimate.
      # `nil` when no spend was recorded: unknown and zero are different facts
      # and the TUI renders them differently.
      cost_usd = reported_cost_usd(subagent_id)

      case result do
        {:ok, response} ->
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
               usage: usage,
               cost_usd: cost_usd,
               output_file: output_file
             }}
          )

          emit_agent_finished(parent_id, subagent_id, display_name, duration_ms, nil, :completed)

        {:error, reason} ->
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
               usage: usage,
               cost_usd: cost_usd,
               output_file: output_file
             }}
          )

          emit_agent_finished(parent_id, subagent_id, display_name, duration_ms, nil, :failed)
      end
    end)

    {:ok, subagent_id}
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

        config =
          %{
            task: task,
            role: run.role,
            agent_id: agent_id,
            fork_messages: transcript,
            working_dir: working_dir
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

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
    |> Enum.count(fn run -> Map.get(run, :status) == :running end)
  rescue
    _ -> 0
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
            tool_count: tool_uses,
            tokens_used: tokens_used,
            worktree: worktree_info,
            resumed_from: resumed_from
          )

        RunStore.complete(subagent_id, structured)

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          display_name: display_name,
          status: "failed",
          error: to_string(reason),
          summary: completion_summary(to_string(reason)),
          tool_uses: tool_uses,
          tokens_used: tokens_used,
          duration_ms: duration_ms,
          batch_id: batch_id
        })

        emit_agent_finished(parent_id, subagent_id, display_name, duration_ms, batch_id, :failed)

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
      watch_for_stall(parent_id, subagent_id, display_name, role, nil, now_ms())
    end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp watch_for_stall(parent_id, subagent_id, display_name, role, last_print, last_change_at) do
    Process.sleep(stall_poll_interval_ms())

    case RunStore.get(subagent_id) do
      %{status: :running} = run ->
        print = progress_fingerprint(run)
        phase = if run.tool_count > 0, do: :working, else: :starting

        cond do
          print != last_print ->
            watch_for_stall(parent_id, subagent_id, display_name, role, print, now_ms())

          now_ms() - last_change_at >= stall_threshold_ms(phase) ->
            emit_stall(
              parent_id,
              subagent_id,
              display_name,
              role,
              phase,
              now_ms() - last_change_at,
              run
            )

          true ->
            watch_for_stall(parent_id, subagent_id, display_name, role, print, last_change_at)
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

  defp failure_result(agent_id, parent_id, role, reason, opts \\ []) do
    structured_result(%{
      agent_id: agent_id,
      parent_session_id: parent_id,
      role: role,
      status: :failed,
      summary: "Subagent #{role} FAILED: #{failure_reason_text(reason)}",
      files_changed: Keyword.get(opts, :files_changed, []),
      commands_run: [],
      tool_count: Keyword.get(opts, :tool_count, 0),
      tokens_used: Keyword.get(opts, :tokens_used, 0),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      errors: [inspect(reason)],
      worktree: Keyword.get(opts, :worktree),
      resumed_from: Keyword.get(opts, :resumed_from)
    })
  end

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

  defp changed_files(nil), do: []

  defp changed_files(%{path: path}) do
    case OptimalSystemAgent.Git.cmd(["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.trim() end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  rescue
    _ -> []
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

        emit_event(parent_id, %{
          event: "orchestrator_agent_progress",
          agent_name: subagent_id,
          current_action: action,
          tool_uses: tool_count,
          tokens_used: forwarder_tokens(subagent_id),
          recent_actions: recent_actions(subagent_id),
          description: ""
        })

        forwarder_loop(subagent_id, parent_id, role, tool_count)

      # Tool call END — increment counter
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase}}
      when phase in ["end", :end] ->
        new_count = tool_count + 1
        RunStore.progress(subagent_id, to_string(tool_name), new_count)

        emit_event(parent_id, %{
          event: "orchestrator_agent_progress",
          agent_name: subagent_id,
          current_action: to_string(tool_name),
          tool_uses: new_count,
          tokens_used: forwarder_tokens(subagent_id),
          recent_actions: recent_actions(subagent_id),
          description: ""
        })

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

  # P8 — config gate for completed-child worktree durable-ref snapshotting.
  #   config :optimal_system_agent, :subagent_worktree_snapshot, true
  # Off by default: snapshotting commits any dirty state into the source
  # repo's object store (via a ref), which is unwanted overhead for callers
  # who don't need post-hoc inspection/resume of discarded worktrees.
  defp subagent_worktree_snapshot? do
    Application.get_env(:optimal_system_agent, :subagent_worktree_snapshot, false) == true
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
