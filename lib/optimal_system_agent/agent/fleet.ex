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
  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Scratchpad

  @default_max_fleet_agents 16
  # Run-lifetime kill switch: absolute ceiling on nodes a single fan_out drains.
  @default_max_fleet_total 1000
  # Per-node wall-clock ceiling for a single fan_out item. A hung node is reaped
  # (its Task killed, slot freed) and recorded as a timed-out result instead of
  # stalling the whole queue forever (the old `timeout: :infinity`). 5 minutes.
  @default_node_timeout_ms 300_000
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
  def spawn_fleet_node(parent_session_id, opts \\ []) when is_binary(parent_session_id) do
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
    * `:spawn_fun` — 2-arity `(parent, opts) -> {:ok, id} | {:error, term}`
      override for the per-item spawn (defaults to `spawn_fleet_node/2`; used to
      exercise the queue-drain without booting real loops).
    * any other opt is forwarded as base spawn opts for each item.

  Returns `{:ok, %{total: T, dropped: D, results: [...]}}` or
  `{:error, :ultra_required}`.
  """
  @spec fan_out(String.t(), [term()], keyword()) ::
          {:ok, %{total: non_neg_integer(), dropped: non_neg_integer(), results: list()}}
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

  defp do_fan_out(parent, items, opts) do
    cap = max_fleet_agents()
    total_cap = max_fleet_total()
    spawn_fun = Keyword.get(opts, :spawn_fun, &spawn_fleet_node/2)
    base_opts = Keyword.drop(opts, [:spawn_fun])

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
    seed_workflow_scratchpad(parent, base_opts, total)

    # Start summary: everything queued, nothing spawned yet.
    emit_fleet_summary(parent, %{queued: total, cap: cap, total_spawned: 0})

    results =
      work
      |> Task.async_stream(
        fn item -> run_fan_out_item(parent, item, spawn_fun, base_opts) end,
        max_concurrency: cap,
        ordered: false,
        # Per-node timeout (was :infinity). A node that runs past the ceiling is
        # KILLED — its slot frees for the next queued item and it surfaces as
        # {:exit, :timeout}, recorded below as a timed-out result. This prevents
        # one hung node from stalling the queue forever.
        timeout: node_timeout_ms(),
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

        case res do
          {:ok, value} -> value
          # Reaped by the per-node timeout: record a timed-out result, keep going.
          {:exit, :timeout} -> {:error, :node_timeout}
          # Any other task exit (crash we couldn't trap): isolate it as an error
          # result so remaining items still drain.
          {:exit, reason} -> {:error, {:exit, reason}}
        end
      end)

    {:ok, %{total: total, dropped: dropped, results: results}}
  end

  # Normalize an item to per-item spawn opts, merge over the shared base opts,
  # and spawn via the full-power path (or the injected spawn_fun in tests).
  defp run_fan_out_item(parent, item, spawn_fun, base_opts) do
    item_opts =
      cond do
        is_binary(item) -> [task: item]
        is_list(item) -> item
        is_map(item) -> Map.to_list(item)
        true -> []
      end

    spawn_fun.(parent, Keyword.merge(base_opts, item_opts))
  rescue
    # Node error isolation: a raising node becomes an error result, its slot
    # frees, and the remaining items keep draining. Never crashes the workflow.
    e -> {:error, {:node_error, Exception.message(e)}}
  catch
    :throw, val -> {:error, {:node_throw, val}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp do_spawn(parent_session_id, opts) do
    agent_type = Keyword.get(opts, :agent_type, @default_agent_type) |> to_string()
    task = Keyword.get(opts, :task, "") |> to_string()
    node_id = Keyword.get(opts, :node_id) || generate_node_id(parent_session_id)
    user_id = Keyword.get(opts, :user_id, "fleet")

    working_dir =
      Keyword.get(opts, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()

    {system_prompt, allowed_tools} = resolve_agent_type(agent_type, Keyword.get(opts, :system_prompt))
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

  @doc "Number of runs currently in the `:running` state (the fleet size)."
  @spec running_count() :: non_neg_integer()
  def running_count do
    RunStore.list(limit: 1_000, status: :running) |> length()
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
    summary = completion_summary(node_id, status, reason)

    RunStore.complete(node_id, %{
      status: status,
      summary: summary,
      tokens_used: node_tokens(node_id)
    })

    emit_fleet_event(parent_id, %{
      event: "fleet_node_completed",
      node_id: node_id,
      summary: summary,
      status: to_string(status)
    })
  end

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
