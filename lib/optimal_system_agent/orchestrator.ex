defmodule OptimalSystemAgent.Orchestrator do
  @moduledoc """
  Subagent lifecycle management: spawn, monitor, collect results, cleanup.

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
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Team

  @doc """
  Run multiple subagents in parallel and collect all results.

  Takes a list of config maps (same format as run_subagent/1).
  Returns a list of {:ok, result} | {:error, reason} in the same order.

  Emits wave events for TUI display when wave numbers are present.
  """
  @spec run_parallel(String.t(), [map()]) :: [{:ok, String.t()} | {:error, term()}]
  def run_parallel(parent_id, configs) when is_list(configs) do
    # Group by wave number (default wave 1)
    waves =
      configs
      |> Enum.with_index()
      |> Enum.group_by(fn {config, _idx} -> Map.get(config, :wave, 1) end)
      |> Enum.sort_by(fn {wave, _} -> wave end)

    total_waves = length(waves)

    # Create team for task tracking
    team_id = "team:#{parent_id}:#{System.unique_integer([:positive])}"

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
            total_waves: total_waves
          })
        end

        # Spawn all tasks in this wave as async Tasks
        tasks =
          Enum.map(indexed_configs, fn {config, original_idx} ->
            config = Map.put(config, :parent_session_id, parent_id)

            {original_idx,
             Task.Supervisor.async_nolink(
               OptimalSystemAgent.TaskSupervisor,
               fn -> run_subagent(config) end
             )}
          end)

        # Wait for all tasks in this wave (10 min timeout per task)
        results =
          Enum.map(tasks, fn {original_idx, task} ->
            result =
              try do
                Task.await(task, 600_000)
              catch
                :exit, {:timeout, _} ->
                  {:error, :timeout}

                :exit, reason ->
                  {:error, reason}
              end

            {original_idx, result}
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

  @doc """
  Run a subagent to completion and return its result.

  Config keys:

    * `:task` - required task description sent to the subagent.
    * `:parent_session_id` - required parent session for event routing.
    * `:role` - display name, such as `"architect"` or `"backend"`.
    * `:tier` - `:elite`, `:specialist`, or `:utility`.
    * `:model` - explicit model override.
    * `:provider` - provider override.
    * `:max_iterations` - override tier default.
    * `:system_prompt` - prompt loaded from agent definition.
    * `:tools_allowed` - allowlist from agent definition.
    * `:tools_blocked` - denylist from agent definition.
    * `:merge_worktree` - explicitly merge successful isolated worktree changes.
    * `:discard_worktree` - explicitly discard isolated worktree changes.
  """
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
    subagent_id =
      Map.get(config, :agent_id) ||
        Map.get(config, :subagent_id) ||
        "agent:#{parent_id}:#{next_subagent_number(parent_id)}"

    task_preview = String.slice(task, 0, 80)

    RunStore.start_run(%{
      agent_id: subagent_id,
      parent_session_id: parent_id,
      role: role,
      task: task
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

    # Emit: agent started
    emit_event(parent_id, %{
      event: "orchestrator_agent_started",
      agent_name: subagent_id,
      role: role,
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

    # Worktree isolation: create an isolated git worktree for this agent.
    isolation = Map.get(config, :isolation)

    worktree_info =
      if isolation == :worktree do
        case OptimalSystemAgent.Agent.Worktree.create(subagent_id) do
          {:ok, info} ->
            Logger.info("[Orchestrator] Worktree created for #{subagent_id} at #{info.path}")
            info

          {:error, reason} ->
            Logger.warning(
              "[Orchestrator] Worktree creation failed: #{reason}, running without isolation"
            )

            nil
        end
      else
        nil
      end

    # Set working directory: worktree path if isolated, otherwise default.
    working_dir =
      if worktree_info,
        do: worktree_info.path,
        else:
          Map.get(config, :working_dir) ||
            Application.get_env(:optimal_system_agent, :working_dir)

    # Spawn the subagent Loop
    subagent_opts = [
      session_id: subagent_id,
      user_id: "subagent",
      channel: :internal,
      permission_tier: Map.get(config, :permission_tier, :subagent),
      model: model,
      provider: provider,
      parent_session_id: parent_id,
      allowed_tools: Map.get(config, :tools_allowed),
      blocked_tools: Map.get(config, :tools_blocked, []),
      system_prompt_override: if(full_prompt != "", do: full_prompt, else: nil),
      messages: fork_messages,
      working_dir: working_dir,
      max_turns: max_iter
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
        result = execute_and_collect(subagent_id, task, parent_id, role, max_iter, worktree_info)

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

        # Worktree cleanup — merge-back is explicit. Dirty worktrees are
        # preserved by default so the parent can inspect/apply changes.
        if worktree_info do
          merge = match?({:ok, _}, result) and Map.get(config, :merge_worktree, false)

          OptimalSystemAgent.Agent.Worktree.cleanup(worktree_info.path,
            merge: merge,
            discard: Map.get(config, :discard_worktree, false)
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
          OptimalSystemAgent.Agent.Worktree.cleanup(worktree_info.path,
            merge: false,
            discard: Map.get(config, :discard_worktree, false)
          )
        end

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          status: "failed",
          error: inspect(reason),
          tool_uses: 0,
          tokens_used: 0
        })

        {:error, reason}
    end
  end

  @doc """
  Run a subagent in the background and return immediately with the agent ID.

  The subagent runs asynchronously under TaskSupervisor. On completion,
  emits `:background_agent_completed` or `:background_agent_failed` on
  the Events.Bus, which the CLI and SSE consumers can display.
  """
  @spec run_background(String.t(), map()) :: {:ok, String.t()}
  def run_background(parent_id, config) do
    config = Map.put(config, :parent_session_id, parent_id)
    role = Map.get(config, :role, "background")

    # Generate the ID upfront so we can return it immediately
    subagent_num = next_subagent_number(parent_id)
    subagent_id = "agent:#{parent_id}:#{subagent_num}"

    emit_event(parent_id, %{
      event: "background_agent_started",
      agent_id: subagent_id,
      role: role
    })

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      start_time = System.monotonic_time(:millisecond)

      result = run_subagent(Map.put(config, :agent_id, subagent_id))
      duration_ms = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, response} ->
          Bus.emit(:system_event, %{
            event: :background_agent_completed,
            session_id: parent_id,
            agent_id: subagent_id,
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
               role: role,
               result: String.slice(response, 0, 500),
               duration_ms: duration_ms
             }}
          )

        {:error, reason} ->
          Bus.emit(:system_event, %{
            event: :background_agent_failed,
            session_id: parent_id,
            agent_id: subagent_id,
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
               role: role,
               error: inspect(reason),
               duration_ms: duration_ms
             }}
          )
      end
    end)

    {:ok, subagent_id}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp execute_and_collect(subagent_id, task, parent_id, role, _max_iter, worktree_info) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        Loop.process_message(subagent_id, task)
      rescue
        e ->
          Logger.error("[Orchestrator] Subagent #{subagent_id} crashed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          Logger.error("[Orchestrator] Subagent #{subagent_id} exited: #{inspect(reason)}")
          {:error, inspect(reason)}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Get metadata from the subagent for the completion event
    {tool_uses, tokens_used} = get_subagent_stats(subagent_id)
    files_changed = changed_files(worktree_info)

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
            commands_run: [],
            tool_count: tool_uses,
            tokens_used: tokens_used,
            duration_ms: duration_ms,
            worktree: worktree_info
          })

        RunStore.complete(subagent_id, structured)

        Logger.info(
          "[Orchestrator] Subagent #{subagent_id} completed in #{duration_ms}ms (#{tool_uses} tools, #{tokens_used} tokens)"
        )

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          status: "completed",
          tool_uses: tool_uses,
          tokens_used: tokens_used,
          result: structured
        })

        {:ok, RunStore.format_result(structured)}

      {:error, reason} ->
        structured =
          failure_result(subagent_id, parent_id, role, reason,
            duration_ms: duration_ms,
            files_changed: files_changed,
            tool_count: tool_uses,
            tokens_used: tokens_used,
            worktree: worktree_info
          )

        RunStore.complete(subagent_id, structured)

        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          status: "failed",
          error: to_string(reason),
          tool_uses: tool_uses,
          tokens_used: tokens_used
        })

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
            commands_run: [],
            tool_count: tool_uses,
            tokens_used: tokens_used,
            duration_ms: duration_ms,
            worktree: worktree_info
          })

        RunStore.complete(subagent_id, structured)

        # Unexpected return: treat as success with inspect.
        emit_event(parent_id, %{
          event: "orchestrator_agent_completed",
          agent_name: subagent_id,
          status: "completed",
          tool_uses: tool_uses,
          tokens_used: tokens_used
        })

        {:ok, inspect(other)}
    end
  end

  defp get_subagent_stats(subagent_id) do
    # Get actual metadata from the Loop GenServer
    meta = Loop.get_metadata(subagent_id)
    tool_count = length(List.wrap(Map.get(meta, :tools_used, [])))

    # Get actual token count from Loop state snapshot
    actual_tokens =
      try do
        case Loop.get_state(subagent_id) do
          {:ok, %{tokens_used: t}} when is_integer(t) and t > 0 -> t
          _ -> tool_count * 500
        end
      rescue
        _ -> tool_count * 500
      catch
        :exit, _ -> tool_count * 500
      end

    {tool_count, actual_tokens}
  rescue
    _ -> {0, 0}
  end

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
      worktree: Map.get(attrs, :worktree)
    }
  end

  defp failure_result(agent_id, parent_id, role, reason, opts \\ []) do
    structured_result(%{
      agent_id: agent_id,
      parent_session_id: parent_id,
      role: role,
      status: :failed,
      summary: "Subagent #{role} failed: #{inspect(reason)}",
      files_changed: Keyword.get(opts, :files_changed, []),
      commands_run: [],
      tool_count: Keyword.get(opts, :tool_count, 0),
      tokens_used: Keyword.get(opts, :tokens_used, 0),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      errors: [inspect(reason)],
      worktree: Keyword.get(opts, :worktree)
    })
  end

  defp changed_files(nil), do: []

  defp changed_files(%{path: path}) do
    case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
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

  # Event forwarder: spawns a Task that listens for subagent tool_call
  # events and re-emits them as orchestrator_agent_progress on the parent channel.
  defp start_event_forwarder(subagent_id, parent_id, role) do
    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      # Subscribe inside this process; PubSub subscriptions are per-process.
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{subagent_id}")
      forwarder_loop(subagent_id, parent_id, role, 0)
    end)
  end

  defp forwarder_loop(subagent_id, parent_id, role, tool_count) do
    receive do
      # Tool call start: update action line with what the tool is doing.
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase, args: args}}
      when phase in ["start", :start] ->
        action = format_action(tool_name, args)
        RunStore.progress(subagent_id, action, tool_count)

        emit_event(parent_id, %{
          event: "orchestrator_agent_progress",
          agent_name: subagent_id,
          role: role,
          current_action: action,
          tool_uses: tool_count,
          tokens_used: tool_count * 500,
          description: ""
        })

        forwarder_loop(subagent_id, parent_id, role, tool_count)

      # Tool call end: increment counter.
      {:osa_event, %{type: :tool_call, name: tool_name, phase: phase}}
      when phase in ["end", :end] ->
        new_count = tool_count + 1
        RunStore.progress(subagent_id, to_string(tool_name), new_count)

        emit_event(parent_id, %{
          event: "orchestrator_agent_progress",
          agent_name: subagent_id,
          role: role,
          current_action: to_string(tool_name),
          tool_uses: new_count,
          tokens_used: new_count * 500,
          description: ""
        })

        forwarder_loop(subagent_id, parent_id, role, new_count)

      _ ->
        forwarder_loop(subagent_id, parent_id, role, tool_count)
    after
      # Stop forwarding after 5 minutes (safety net)
      300_000 -> :ok
    end
  end

  # Format a human-readable action string from tool name + args hint.
  # e.g., "file_read /Users/roberto/..." or "web_search Rust TUI frameworks"
  defp format_action(tool_name, args) when is_binary(args) do
    hint = String.slice(args, 0, 60)

    if hint == "" or hint == "{}" do
      to_string(tool_name)
    else
      "#{tool_name}: #{hint}"
    end
  end

  defp format_action(tool_name, _), do: to_string(tool_name)

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
    # Node-unique monotonic integer avoids ETS ownership issues and races.
    System.unique_integer([:positive, :monotonic])
  end
end
