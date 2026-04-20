defmodule OptimalSystemAgent.Agent.Hooks do
  @moduledoc """
  Middleware pipeline for agent lifecycle events.

  Built-in hooks (6):
    security_check   — pre_tool_use  (p10)  block dangerous shell commands
    spend_guard      — pre_tool_use  (p8)   block when budget exceeded
    mcp_cache        — pre_tool_use  (p15)  inject cached MCP schemas
    cost_tracker     — post_tool_use (p25)  record actual API spend
    mcp_cache_post   — post_tool_use (p15)  populate MCP schema cache
    telemetry        — post_tool_use (p90)  emit tool timing telemetry

  Each hook is a function that receives a payload map and returns:
    {:ok, payload}     — continue with (possibly modified) payload
    {:block, reason}   — block the action (pre_tool_use only)
    :skip              — skip this hook silently

  Hooks run in priority order (lower = first). If any hook blocks, the chain stops.

  Architecture:
    - Registration goes through GenServer (serialized writes)
    - Hook data stored in ETS `:osa_hooks` (bag, read_concurrency: true)
    - Execution reads from ETS in caller's process (no GenServer bottleneck)
    - Metrics tracked in ETS `:osa_hooks_metrics` (atomic counters, write_concurrency: true)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @type hook_event ::
          :pre_tool_use
          | :post_tool_use
          | :post_tool_use_failure
          | :user_prompt_submit
          | :pre_compact
          | :post_compact
          | :session_start
          | :session_end
          | :pre_response
          | :post_response
          | :pre_session_resume
          | :session_error
          | :subagent_start
          | :subagent_stop
          | :task_completed
          | :task_failed
          | :permission_request
          | :permission_granted
          | :permission_denied
          | :file_changed
          | :file_read
          | :worktree_create
          | :worktree_remove
  @type hook_fn :: (map() -> {:ok, map()} | {:block, String.t()} | :skip)
  @type hook_entry :: %{
          name: String.t(),
          event: hook_event(),
          handler: hook_fn(),
          priority: integer()
        }

  @hooks_table :osa_hooks
  @metrics_table :osa_hooks_metrics

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a hook for an event.
  Priority: lower number = runs first. Default: 50.
  """
  @spec register(hook_event(), String.t(), hook_fn(), keyword()) :: :ok
  def register(event, name, handler, opts \\ []) do
    priority = Keyword.get(opts, :priority, 50)
    GenServer.cast(__MODULE__, {:register, event, name, handler, priority})
  end

  @doc """
  Run all hooks for an event. Returns the final payload or a block reason.
  Executes in the caller's process by reading from ETS — no GenServer call.
  """
  @spec run(hook_event(), map()) :: {:ok, map()} | {:blocked, String.t()}
  def run(event, payload) do
    hooks = hooks_for_event(event)
    started_at = System.monotonic_time(:microsecond)
    result = run_chain(hooks, payload, event)
    elapsed_us = System.monotonic_time(:microsecond) - started_at
    update_metrics_ets(event, elapsed_us, result)
    result
  end

  @doc """
  Run hooks asynchronously (fire-and-forget). Use for post-event hooks
  whose results are not needed by the caller (e.g. post_tool_use).
  """
  @spec run_async(hook_event(), map()) :: :ok
  def run_async(event, payload) do
    Task.start(fn ->
      hooks = hooks_for_event(event)
      started_at = System.monotonic_time(:microsecond)
      result = run_chain(hooks, payload, event)
      elapsed_us = System.monotonic_time(:microsecond) - started_at
      update_metrics_ets(event, elapsed_us, result)
    end)
    :ok
  end

  @doc "List registered hooks."
  @spec list_hooks() :: %{hook_event() => [%{name: String.t(), priority: integer()}]}
  def list_hooks do
    all_hooks = :ets.tab2list(@hooks_table)

    all_hooks
    |> Enum.group_by(fn {event, _name, _priority, _handler} -> event end)
    |> Enum.map(fn {event, entries} ->
      hooks =
        entries
        |> Enum.sort_by(fn {_event, _name, priority, _handler} -> priority end)
        |> Enum.map(fn {_event, name, priority, _handler} -> %{name: name, priority: priority} end)

      {event, hooks}
    end)
    |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc "Get hook execution metrics."
  @spec metrics() :: map()
  def metrics do
    @metrics_table
    |> :ets.tab2list()
    |> Enum.group_by(fn {{event, _metric}, _val} -> event end)
    |> Enum.map(fn {event, entries} ->
      kv = Map.new(entries, fn {{_event, metric}, val} -> {metric, val} end)
      calls = Map.get(kv, :calls, 0)
      total_us = Map.get(kv, :total_us, 0)
      blocks = Map.get(kv, :blocks, 0)
      avg_us = if calls > 0, do: div(total_us, calls), else: 0

      {event, %{calls: calls, total_us: total_us, blocks: blocks, avg_us: avg_us}}
    end)
    |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  # ── ETS Helpers (public for testing) ─────────────────────────────

  @doc false
  def hooks_table_name, do: @hooks_table

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    # ETS table for hook definitions (read from caller process, written via GenServer)
    if :ets.whereis(@hooks_table) == :undefined do
      :ets.new(@hooks_table, [:named_table, :bag, :public, {:read_concurrency, true}])
    end

    # ETS table for metrics counters (atomic updates from any process, no GenServer bottleneck)
    if :ets.whereis(@metrics_table) == :undefined do
      :ets.new(@metrics_table, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    # Register built-in hooks
    register_builtins()

    hook_count =
      try do
        :ets.info(@hooks_table, :size)
      rescue
        _ -> 0
      end

    Logger.info("[Hooks] Pipeline initialized with #{hook_count} hooks")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:register, event, name, handler, priority}, state) do
    :ets.insert(@hooks_table, {event, name, priority, handler})
    {:noreply, state}
  end


  # ── Hook Chain Execution (runs in caller process) ──────────────

  defp hooks_for_event(event) do
    entries = :ets.lookup(@hooks_table, event)

    entries
    |> Enum.sort_by(fn {_event, _name, priority, _handler} -> priority end)
    |> Enum.map(fn {_event, name, priority, handler} ->
      %{name: name, priority: priority, handler: handler}
    end)
  rescue
    ArgumentError -> []
  end

  defp run_chain([], payload, _event), do: {:ok, payload}

  defp run_chain([hook | rest], payload, event) do
    try do
      case hook.handler.(payload) do
        {:ok, updated_payload} ->
          run_chain(rest, updated_payload, event)

        {:block, reason} ->
          Logger.warning("[Hooks] #{hook.name} blocked #{event}: #{reason}")

          Bus.emit(:system_event, %{
            event: :hook_blocked,
            hook_name: hook.name,
            hook_event: event,
            reason: reason,
            session_id: Map.get(payload, :session_id, "unknown")
          })

          {:blocked, reason}

        :skip ->
          run_chain(rest, payload, event)

        other ->
          Logger.warning("[Hooks] #{hook.name} returned unexpected: #{inspect(other)}")
          run_chain(rest, payload, event)
      end
    rescue
      e ->
        Logger.error("[Hooks] #{hook.name} crashed: #{Exception.message(e)}")
        # Don't let a broken hook crash the pipeline
        run_chain(rest, payload, event)
    end
  end

  # ── Built-in Hooks ────────────────────────────────────────────────

  defp register_builtins do
    builtins = [
      # Spend guard — blocks when budget exceeded (pre_tool_use, priority 8)
      %{
        name: "spend_guard",
        event: :pre_tool_use,
        priority: 8,
        handler: &spend_guard/1
      },

      # Security check — block dangerous commands (pre_tool_use, priority 10)
      %{
        name: "security_check",
        event: :pre_tool_use,
        priority: 10,
        handler: &security_check/1
      },

      # MCP schema cache — inject cached schema if fresh (pre_tool_use, priority 15)
      %{
        name: "mcp_cache",
        event: :pre_tool_use,
        priority: 15,
        handler: &mcp_cache_pre/1
      },

      # MCP schema cache — populate cache after tool use (post_tool_use, priority 15)
      %{
        name: "mcp_cache_post",
        event: :post_tool_use,
        priority: 15,
        handler: &mcp_cache_post/1
      },

      # Cost tracker — records actual spend after tool use (post_tool_use, priority 25)
      %{
        name: "cost_tracker",
        event: :post_tool_use,
        priority: 25,
        handler: &cost_tracker/1
      },

      # Read-before-write nudge — warns when file_edit/file_write targets an unread file
      # (pre_tool_use, priority 12 — after security_check at 10)
      %{
        name: "read_before_write",
        event: :pre_tool_use,
        priority: 12,
        handler: &read_before_write/1
      },

      # Track files read — records file paths after read/glob/dir_list
      # (post_tool_use, priority 5 — runs early so data is available)
      %{
        name: "track_files_read",
        event: :post_tool_use,
        priority: 5,
        handler: &track_files_read/1
      },

      # Telemetry (post_tool_use, priority 90)
      %{
        name: "telemetry",
        event: :post_tool_use,
        priority: 90,
        handler: &telemetry_hook/1
      },

      # Session cleanup — remove :osa_files_read ETS entries when session ends
      # to prevent unbounded memory growth (session_end, priority 90)
      %{
        name: "session_cleanup",
        event: :session_end,
        priority: 90,
        handler: &session_cleanup/1
      },

      # Vault auto-checkpoint — periodic vault save on tool use (post_tool_use, priority 80)
      %{
        name: "vault_auto_checkpoint",
        event: :post_tool_use,
        priority: 80,
        handler: &vault_auto_checkpoint/1
      },

      # SICA learning observer — record tool outcomes for pattern learning (post_tool_use, priority 95)
      %{
        name: "learning_observer",
        event: :post_tool_use,
        priority: 95,
        handler: &learning_observer/1
      },

      # Episodic memory recorder — log tool events into ETS for context injection (post_tool_use, priority 90)
      %{
        name: "episodic_recorder",
        event: :post_tool_use,
        priority: 90,
        handler: &episodic_recorder/1
      },

      # Save transcript — persist conversation turns for cross-session search
      %{
        name: "save_transcript",
        event: :post_response,
        priority: 85,
        handler: &save_transcript/1
      },

      # Auto-save session state — persist full conversation for resume
      %{
        name: "auto_save_session",
        event: :post_response,
        priority: 95,
        handler: fn %{session_id: sid} = payload when is_binary(sid) ->
          try do
            OptimalSystemAgent.Agent.SessionPersistence.auto_save(sid)
          rescue
            _ -> :ok
          end
          {:ok, payload}
        end
      }
    ]

    Enum.each(builtins, fn hook ->
      :ets.insert(@hooks_table, {hook.event, hook.name, hook.priority, hook.handler})
    end)
  end

  # ── Built-in Hook Implementations ────────────────────────────────

  # Security check — basic dangerous command blocking (Security module removed)
  defp security_check(%{tool_name: "shell_execute", arguments: %{"command" => cmd}} = payload) do
    dangerous_patterns = [~r/rm\s+-rf\s+\//, ~r/:(){ :|:& };:/, ~r/mkfs/, ~r/dd\s+.*of=\/dev/]

    if Enum.any?(dangerous_patterns, &Regex.match?(&1, cmd)) do
      {:block, "Blocked potentially dangerous command"}
    else
      {:ok, payload}
    end
  end

  defp security_check(payload), do: {:ok, payload}

  # Spend guard — check budget limits before tool execution
  defp spend_guard(payload) do
    try do
      case OptimalSystemAgent.Budget.check_budget() do
        {:ok, _remaining} ->
          {:ok, payload}

        {:over_limit, period} ->
          {:block, "Budget exceeded (#{period} limit reached). Use /budget to check status."}
      end
    catch
      :exit, _ ->
        # Budget GenServer not running — allow through
        {:ok, payload}
    end
  end

  # Cost tracker — record actual API costs after tool use
  defp cost_tracker(%{tool_name: _name, result: _result} = payload) do
    try do
      provider = Map.get(payload, :provider, "unknown")
      model = Map.get(payload, :model, "unknown")
      tokens_in = Map.get(payload, :tokens_in, 0)
      tokens_out = Map.get(payload, :tokens_out, 0)
      session_id = Map.get(payload, :session_id, "unknown")

      if tokens_in > 0 or tokens_out > 0 do
        OptimalSystemAgent.Budget.record_cost(
          provider,
          model,
          tokens_in,
          tokens_out,
          session_id
        )
      end
    catch
      :exit, _ -> :ok
    end

    {:ok, payload}
  end

  defp cost_tracker(payload), do: {:ok, payload}

  # Telemetry collection
  defp telemetry_hook(%{tool_name: name, duration_ms: ms} = payload) do
    Bus.emit(:system_event, %{
      event: :tool_telemetry,
      tool_name: name,
      duration_ms: ms,
      timestamp: DateTime.utc_now()
    })

    {:ok, payload}
  end

  defp telemetry_hook(payload), do: {:ok, payload}


  # Read-before-write — nudge when file_edit/file_write targets an existing file
  # that hasn't been read yet. Does NOT block — just adds a flag to the payload.
  defp read_before_write(%{tool_name: tool_name, arguments: args, session_id: sid} = payload)
       when tool_name in ["file_edit", "file_write"] do
    path = args["path"]

    if is_binary(path) and File.exists?(path) do
      # Check if file was already read in this session
      read_key = {sid, path}

      already_read =
        try do
          case :ets.lookup(:osa_files_read, read_key) do
            [{^read_key, true}] -> true
            _ -> false
          end
        rescue
          ArgumentError -> false
        end

      if already_read do
        {:ok, payload}
      else
        # Check nudge count — max 2 per session per file to avoid doom loops
        nudge_key = {sid, :nudge_count, path}

        nudge_count =
          try do
            :ets.update_counter(:osa_files_read, nudge_key, {2, 1}, {nudge_key, 0})
          rescue
            ArgumentError -> 1
          end

        if nudge_count > 2 do
          {:ok, payload}
        else

          {:ok,
           Map.put(
             payload,
             :nudge,
             "[Read-before-write] You're modifying #{path} without reading it first. " <>
               "Call file_read on #{path} to understand its current content before editing."
           )}
        end
      end
    else
      {:ok, payload}
    end
  end

  defp read_before_write(payload), do: {:ok, payload}

  # Track files read — records file paths in ETS after successful file_read/dir_list/glob.
  # ToolExecutor normalizes the result to a plain string before building the post_payload,
  # so we match on a binary result and exclude error/blocked strings.
  defp track_files_read(
         %{tool_name: tool_name, arguments: args, session_id: sid, result: result} = payload
       )
       when tool_name in ["file_read", "dir_list", "glob"] and is_binary(result) and
              not (result == "") do
    # Only record on success — skip Error:/Blocked: responses
    if String.starts_with?(result, "Error:") or String.starts_with?(result, "Blocked:") do
      {:ok, payload}
    else
      path = args["path"] || args["pattern"] || ""

      if is_binary(path) and path != "" do
        try do
          :ets.insert(:osa_files_read, {{sid, path}, true})
        rescue
          ArgumentError -> :ok
        end
      end

      {:ok, payload}
    end
  end

  defp track_files_read(payload), do: {:ok, payload}

  # Session cleanup — remove all ETS entries for the session when it ends
  defp session_cleanup(%{session_id: sid} = payload) do
    try do
      :ets.match_delete(:osa_files_read, {{sid, :_}, :_})
      :ets.match_delete(:osa_files_read, {{sid, :nudge_count, :_}, :_})
    rescue
      ArgumentError -> :ok
    end

    {:ok, payload}
  end

  defp session_cleanup(payload), do: {:ok, payload}

  # Vault auto-checkpoint — save vault state every N tool calls
  defp vault_auto_checkpoint(%{session_id: sid} = payload) when is_binary(sid) do
    # Use ETS counter to checkpoint every 10 tool calls
    counter_key = {:vault_checkpoint_counter, sid}

    count =
      try do
        :ets.update_counter(@metrics_table, counter_key, {2, 1})
      rescue
        ArgumentError ->
          try do
            :ets.insert_new(@metrics_table, {counter_key, 1})
            1
          rescue
            _ -> 0
          end
      end

    # Vault module removed — no-op checkpoint
    _ = count

    {:ok, payload}
  end

  defp vault_auto_checkpoint(payload), do: {:ok, payload}

  # SICA learning observer — record tool use outcomes for pattern learning
  defp learning_observer(%{tool_name: tool_name, result: result} = payload) do
    duration_ms = Map.get(payload, :duration_ms)

    {type, error_message, snippet} =
      if is_binary(result) and
           (String.starts_with?(result, "Error:") or String.starts_with?(result, "Blocked:")) do
        {:failure, result, nil}
      else
        snippet = if is_binary(result), do: String.slice(result, 0, 200), else: nil
        {:success, nil, snippet}
      end

    interaction = %{
      type: type,
      tool_name: tool_name,
      duration_ms: duration_ms,
      result_snippet: snippet,
      error_message: error_message,
      context: %{session_id: Map.get(payload, :session_id)}
    }

    OptimalSystemAgent.Memory.Learning.observe(interaction)

    {:ok, payload}
  end

  defp learning_observer(payload), do: {:ok, payload}

  # Episodic memory recorder — log tool use events into ETS so context.ex can inject them
  defp episodic_recorder(%{tool_name: tool_name, result: result} = payload) do
    session_id = Map.get(payload, :session_id, "unknown")
    duration_ms = Map.get(payload, :duration_ms)

    success? =
      not (is_binary(result) and
             (String.starts_with?(result, "Error:") or String.starts_with?(result, "Blocked:")))

    content = %{
      tool: tool_name,
      success: success?,
      duration_ms: duration_ms,
      snippet: if(is_binary(result), do: String.slice(result, 0, 120), else: nil)
    }

    OptimalSystemAgent.Agent.Memory.Episodic.record(:tool_use, content, session_id)
    {:ok, payload}
  rescue
    _ -> {:ok, payload}
  end

  defp episodic_recorder(payload), do: {:ok, payload}

  # Save transcript — persist user input and assistant response for cross-session search
  defp save_transcript(%{session_id: sid, input: input, response: response} = payload)
       when is_binary(sid) do
    alias OptimalSystemAgent.Store.SessionTranscript

    try do
      if is_binary(input) and input != "" do
        SessionTranscript.save_turn(sid, "user", input)

        # Auto-extract memories from user messages
        extractions = OptimalSystemAgent.Memory.AutoExtract.extract(input)
        if extractions != [] do
          OptimalSystemAgent.Memory.AutoExtract.save_extracted(extractions, sid)
        end
      end

      if is_binary(response) and response != "" do
        SessionTranscript.save_turn(sid, "assistant", response)
      end
    rescue
      _ -> :ok
    end

    {:ok, payload}
  end

  defp save_transcript(payload), do: {:ok, payload}

  # MCP cache — pre_tool_use: inject cached schema if fresh (< 1 hour)
  defp mcp_cache_pre(%{tool_name: tool_name} = payload) when is_binary(tool_name) do
    if String.starts_with?(tool_name, "mcp_") do
      cache_key = {__MODULE__, :mcp_schema, tool_name}

      case :persistent_term.get(cache_key, nil) do
        %{schema: schema, cached_at: cached_at} ->
          age_seconds = DateTime.diff(DateTime.utc_now(), cached_at, :second)

          if age_seconds < 3600 do
            {:ok, Map.put(payload, :cached_schema, schema)}
          else
            {:ok, payload}
          end

        nil ->
          {:ok, payload}
      end
    else
      {:ok, payload}
    end
  end

  defp mcp_cache_pre(payload), do: {:ok, payload}

  # MCP cache — post_tool_use: store schema from result
  defp mcp_cache_post(%{tool_name: tool_name, result: result} = payload)
       when is_binary(tool_name) and is_binary(result) do
    if String.starts_with?(tool_name, "mcp_") do
      cache_key = {__MODULE__, :mcp_schema, tool_name}

      :persistent_term.put(cache_key, %{
        schema: result,
        cached_at: DateTime.utc_now()
      })
    end

    {:ok, payload}
  end

  defp mcp_cache_post(payload), do: {:ok, payload}

  # ── Helpers ────────────────────────────────────────────────────────

  defp update_metrics_ets(event, elapsed_us, result) do
    :ets.update_counter(@metrics_table, {event, :calls}, {2, 1}, {{event, :calls}, 0})
    :ets.update_counter(@metrics_table, {event, :total_us}, {2, elapsed_us}, {{event, :total_us}, 0})

    if match?({:blocked, _}, result) do
      :ets.update_counter(@metrics_table, {event, :blocks}, {2, 1}, {{event, :blocks}, 0})
    end
  rescue
    ArgumentError -> :ok
  end
end
