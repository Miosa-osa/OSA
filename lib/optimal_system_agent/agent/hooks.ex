defmodule OptimalSystemAgent.Agent.Hooks do
  @moduledoc """
  Middleware pipeline for agent lifecycle events.

  Hooks intercept key moments in the agent lifecycle:
    :pre_tool_use    — before a tool executes (can block, modify, or log)
    :post_tool_use   — after a tool executes (capture learnings, errors, metrics)
    :pre_compact     — before context compaction (snapshot state)
    :session_start   — when a new session begins (inject context, load memory)
    :session_end     — when a session ends (log, consolidate, save patterns)
    :pre_response    — before sending response to user (quality check)
    :post_response   — after response sent (telemetry, learning capture)

  Each hook is a function that receives a payload map and returns:
    {:ok, payload}     — continue with (possibly modified) payload
    {:block, reason}   — block the action (pre_tool_use only)
    :skip              — skip this hook silently

  Hooks run in order. If any hook blocks, the chain stops.

  Based on: OSA Agent v3.3 hook system (13 events, 17 scripts)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @type hook_event ::
          :pre_tool_use
          | :post_tool_use
          | :pre_compact
          | :session_start
          | :session_end
          | :pre_response
          | :post_response
  @type hook_fn :: (map() -> {:ok, map()} | {:block, String.t()} | :skip)
  @type hook_entry :: %{
          name: String.t(),
          event: hook_event(),
          handler: hook_fn(),
          priority: integer()
        }

  defstruct hooks: %{}, metrics: %{}

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
  """
  @spec run(hook_event(), map()) :: {:ok, map()} | {:blocked, String.t()}
  def run(event, payload) do
    GenServer.call(__MODULE__, {:run, event, payload}, 10_000)
  end

  @doc """
  Run hooks asynchronously (fire-and-forget). Use for post-event hooks
  whose results are not needed by the caller (e.g. post_tool_use).
  """
  @spec run_async(hook_event(), map()) :: :ok
  def run_async(event, payload) do
    GenServer.cast(__MODULE__, {:run_async, event, payload})
  end

  @doc "List registered hooks."
  @spec list_hooks() :: %{hook_event() => [%{name: String.t(), priority: integer()}]}
  def list_hooks do
    GenServer.call(__MODULE__, :list_hooks)
  end

  @doc "Get hook execution metrics."
  @spec metrics() :: map()
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %__MODULE__{hooks: %{}, metrics: %{}}

    # ETS table for hot-path counters (replaces persistent_term.put on write-heavy paths)
    :ets.new(:osa_hooks_counters, [:named_table, :public, :set])
    :ets.insert(:osa_hooks_counters, {:metrics_calls, 0})
    :ets.insert(:osa_hooks_counters, {:tools_loaded, 0})

    # Register built-in hooks
    state = register_builtins(state)

    Logger.info("[Hooks] Pipeline initialized with #{count_hooks(state)} hooks")
    {:ok, state}
  end

  @impl true
  def handle_cast({:register, event, name, handler, priority}, state) do
    entry = %{name: name, event: event, handler: handler, priority: priority}

    hooks_for_event = Map.get(state.hooks, event, [])
    updated = [entry | hooks_for_event] |> Enum.sort_by(& &1.priority)

    {:noreply, %{state | hooks: Map.put(state.hooks, event, updated)}}
  end

  @impl true
  def handle_cast({:run_async, event, payload}, state) do
    hooks = Map.get(state.hooks, event, [])
    started_at = System.monotonic_time(:microsecond)
    {result, state} = run_chain(hooks, payload, event, state)
    elapsed_us = System.monotonic_time(:microsecond) - started_at
    state = update_metrics(state, event, elapsed_us, result)
    {:noreply, state}
  end

  @impl true
  def handle_call({:run, event, payload}, _from, state) do
    hooks = Map.get(state.hooks, event, [])
    started_at = System.monotonic_time(:microsecond)

    {result, state} = run_chain(hooks, payload, event, state)

    elapsed_us = System.monotonic_time(:microsecond) - started_at
    state = update_metrics(state, event, elapsed_us, result)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_hooks, _from, state) do
    listing =
      state.hooks
      |> Enum.map(fn {event, hooks} ->
        {event, Enum.map(hooks, fn h -> %{name: h.name, priority: h.priority} end)}
      end)
      |> Map.new()

    {:reply, listing, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  # ── Hook Chain Execution ──────────────────────────────────────────

  defp run_chain([], payload, _event, state), do: {{:ok, payload}, state}

  defp run_chain([hook | rest], payload, event, state) do
    try do
      case hook.handler.(payload) do
        {:ok, updated_payload} ->
          run_chain(rest, updated_payload, event, state)

        {:block, reason} ->
          Logger.warning("[Hooks] #{hook.name} blocked #{event}: #{reason}")

          Bus.emit(:system_event, %{
            event: :hook_blocked,
            hook_name: hook.name,
            hook_event: event,
            reason: reason
          })

          {{:blocked, reason}, state}

        :skip ->
          run_chain(rest, payload, event, state)

        other ->
          Logger.warning("[Hooks] #{hook.name} returned unexpected: #{inspect(other)}")
          run_chain(rest, payload, event, state)
      end
    rescue
      e ->
        Logger.error("[Hooks] #{hook.name} crashed: #{Exception.message(e)}")
        # Don't let a broken hook crash the pipeline
        run_chain(rest, payload, event, state)
    end
  end

  # ── Built-in Hooks ────────────────────────────────────────────────

  defp register_builtins(state) do
    builtins = [
      # Security check — block dangerous commands (pre_tool_use, priority 10)
      %{
        name: "security_check",
        event: :pre_tool_use,
        priority: 10,
        handler: &security_check/1
      },

      # Spend guard — blocks when budget exceeded (pre_tool_use, priority 8)
      %{
        name: "spend_guard",
        event: :pre_tool_use,
        priority: 8,
        handler: &spend_guard/1
      },

      # Token budget tracking (pre_tool_use, priority 20)
      %{
        name: "budget_tracker",
        event: :pre_tool_use,
        priority: 20,
        handler: &budget_tracker/1
      },

      # Cost tracker — records actual spend after tool use (post_tool_use, priority 25)
      %{
        name: "cost_tracker",
        event: :post_tool_use,
        priority: 25,
        handler: &cost_tracker/1
      },

      # Learning capture (post_tool_use, priority 50)
      %{
        name: "learning_capture",
        event: :post_tool_use,
        priority: 50,
        handler: &learning_capture/1
      },

      # Error recovery (post_tool_use, priority 30)
      %{
        name: "error_recovery",
        event: :post_tool_use,
        priority: 30,
        handler: &error_recovery/1
      },

      # Telemetry (post_tool_use, priority 90)
      %{
        name: "telemetry",
        event: :post_tool_use,
        priority: 90,
        handler: &telemetry_hook/1
      },

      # Session context injection (session_start, priority 10)
      %{
        name: "context_injection",
        event: :session_start,
        priority: 10,
        handler: &context_injection/1
      },

      # Response quality check (pre_response, priority 50)
      %{
        name: "quality_check",
        event: :pre_response,
        priority: 50,
        handler: &quality_check/1
      },

      # Episodic memory — write novel interactions to JSONL (post_tool_use, priority 60)
      %{
        name: "episodic_memory",
        event: :post_tool_use,
        priority: 60,
        handler: &episodic_memory/1
      },

      # Metrics dashboard — track token efficiency per tool call (post_tool_use, priority 80)
      %{
        name: "metrics_dashboard",
        event: :post_tool_use,
        priority: 80,
        handler: &metrics_dashboard/1
      },

      # Prompt validation — inject contextual hints based on keywords (pre_response, priority 20)
      %{
        name: "validate_prompt",
        event: :pre_response,
        priority: 20,
        handler: &validate_prompt/1
      },

      # Hierarchical compaction — warn and signal at context utilization thresholds (post_tool_use, priority 95)
      %{
        name: "hierarchical_compaction",
        event: :post_tool_use,
        priority: 95,
        handler: &hierarchical_compaction/1
      },

      # Auto-format — suggest a formatter for file write/edit operations (post_tool_use, priority 85)
      %{
        name: "auto_format",
        event: :post_tool_use,
        priority: 85,
        handler: &auto_format/1
      },

      # MCP schema cache — cache tool schemas in :persistent_term (pre_tool_use, priority 15)
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

      # Pattern consolidation — detect repeated tool patterns at session end (session_end, priority 80)
      %{
        name: "pattern_consolidation",
        event: :session_end,
        priority: 80,
        handler: &pattern_consolidation/1
      },

      # Context optimizer — suggest lazy loading after 20 tools loaded (pre_tool_use, priority 12)
      %{
        name: "context_optimizer",
        event: :pre_tool_use,
        priority: 12,
        handler: &context_optimizer/1
      }
    ]

    Enum.reduce(builtins, state, fn hook, acc ->
      hooks_for_event = Map.get(acc.hooks, hook.event, [])
      updated = [hook | hooks_for_event] |> Enum.sort_by(& &1.priority)
      %{acc | hooks: Map.put(acc.hooks, hook.event, updated)}
    end)
  end

  # ── Built-in Hook Implementations ────────────────────────────────

  # Block dangerous shell commands — delegates to the single source of truth.
  defp security_check(%{tool_name: "shell_execute", arguments: %{"command" => cmd}} = payload) do
    case OptimalSystemAgent.Security.ShellPolicy.validate(cmd) do
      :ok -> {:ok, payload}
      {:error, reason} -> {:block, "Blocked dangerous command: #{reason}"}
    end
  end

  defp security_check(payload), do: {:ok, payload}

  # Spend guard — check budget limits before tool execution
  defp spend_guard(payload) do
    try do
      case OptimalSystemAgent.Agent.Budget.check_budget() do
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

  # Track token budget (lightweight annotation)
  defp budget_tracker(payload) do
    {:ok, Map.put(payload, :budget_check, :passed)}
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
        OptimalSystemAgent.Agent.Budget.record_cost(
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

  # Capture learnings from tool use
  defp learning_capture(%{tool_name: name, result: result, duration_ms: ms} = payload)
       when is_binary(result) do
    # Emit for the learning engine to pick up
    Bus.emit(:system_event, %{
      event: :tool_learning,
      tool_name: name,
      duration_ms: ms,
      result_length: String.length(result),
      success: not String.starts_with?(result, "Error:")
    })

    {:ok, payload}
  end

  defp learning_capture(payload), do: {:ok, payload}

  # Error recovery suggestions
  defp error_recovery(%{result: result} = payload) when is_binary(result) do
    if String.starts_with?(result, "Error:") do
      recovery = suggest_recovery(result)

      Bus.emit(:system_event, %{
        event: :error_detected,
        error: String.slice(result, 0, 200),
        recovery_suggestion: recovery
      })

      {:ok, Map.put(payload, :recovery_suggestion, recovery)}
    else
      {:ok, payload}
    end
  end

  defp error_recovery(payload), do: {:ok, payload}

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

  # Inject recent context at session start
  defp context_injection(%{session_id: _sid} = payload) do
    # The memory system will handle loading recent context
    # This hook just marks the session as initialized
    {:ok, Map.put(payload, :context_injected, true)}
  end

  defp context_injection(payload), do: {:ok, payload}

  # Response quality check
  defp quality_check(%{content: content} = payload) when is_binary(content) do
    cond do
      String.length(content) == 0 ->
        {:ok, Map.put(payload, :quality, :empty)}

      String.length(content) < 10 ->
        {:ok, Map.put(payload, :quality, :minimal)}

      true ->
        {:ok, Map.put(payload, :quality, :ok)}
    end
  end

  defp quality_check(payload), do: {:ok, payload}

  # Episodic memory — persist novel tool interactions to JSONL
  defp episodic_memory(%{tool_name: tool_name, result: result, session_id: session_id} = payload)
       when is_binary(result) do
    info_score =
      cond do
        String.starts_with?(result, "Error:") -> 0.8
        String.length(result) > 500 -> 0.5
        true -> 0.2
      end

    if info_score >= 0.25 do
      home = System.user_home!()
      date = Date.utc_today() |> Date.to_string()
      dir = Path.join([home, ".osa", "learning", "episodes"])
      path = Path.join(dir, "#{date}-episodes.jsonl")

      id =
        :crypto.hash(:sha256, "#{tool_name}#{result}#{System.monotonic_time()}")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      entry = %{
        id: id,
        type: "interaction",
        tool_name: tool_name,
        result_preview: String.slice(result, 0, 200),
        info_score: info_score,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        session_id: session_id
      }

      try do
        File.mkdir_p!(dir)
        File.write!(path, Jason.encode!(entry) <> "\n", [:append])
      rescue
        e -> Logger.warning("[Hooks] episodic_memory write failed: #{Exception.message(e)}")
      end
    end

    {:ok, payload}
  end

  defp episodic_memory(payload), do: {:ok, payload}

  # Metrics dashboard — track per-tool timing and write daily JSONL
  defp metrics_dashboard(
         %{tool_name: tool_name, duration_ms: duration_ms, result: result} = payload
       ) do
    home = System.user_home!()
    dir = Path.join([home, ".osa", "metrics"])
    daily_path = Path.join(dir, "daily.json")

    success = not (is_binary(result) and String.starts_with?(result, "Error:"))

    entry = %{
      tool_name: tool_name,
      duration_ms: duration_ms,
      success: success,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    try do
      File.mkdir_p!(dir)
      File.write!(daily_path, Jason.encode!(entry) <> "\n", [:append])

      # Every 100 calls, compute summary stats (ETS counter — no global GC pressure)
      count = :ets.update_counter(:osa_hooks_counters, :metrics_calls, {2, 1})

      if rem(count, 100) == 0 do
        write_metrics_summary(dir, daily_path)
      end
    rescue
      e -> Logger.warning("[Hooks] metrics_dashboard write failed: #{Exception.message(e)}")
    end

    {:ok, payload}
  end

  defp metrics_dashboard(payload), do: {:ok, payload}

  defp write_metrics_summary(dir, daily_path) do
    summary_path = Path.join(dir, "summary.json")

    try do
      lines =
        daily_path
        |> File.stream!()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Jason.decode!/1)

      total = length(lines)
      successes = Enum.count(lines, & &1["success"])
      durations = Enum.map(lines, & &1["duration_ms"]) |> Enum.reject(&is_nil/1)

      avg_duration =
        if durations == [], do: 0, else: Enum.sum(durations) / length(durations)

      by_tool =
        lines
        |> Enum.group_by(& &1["tool_name"])
        |> Enum.map(fn {name, calls} -> {name, length(calls)} end)
        |> Map.new()

      summary = %{
        total_calls: total,
        success_rate: if(total > 0, do: successes / total, else: 0.0),
        avg_duration_ms: avg_duration,
        calls_by_tool: by_tool,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(summary_path, Jason.encode!(summary, pretty: true))
    rescue
      e -> Logger.warning("[Hooks] metrics summary write failed: #{Exception.message(e)}")
    end
  end

  # Validate prompt — inject contextual hints based on content keywords
  defp validate_prompt(%{content: content} = payload) when is_binary(content) do
    lower = String.downcase(content)

    hints =
      []
      |> maybe_add_hint(
        lower,
        ~r/\btest\b/,
        "TDD: write the failing test first (RED → GREEN → REFACTOR)"
      )
      |> maybe_add_hint(
        lower,
        ~r/\b(bug|error)\b/,
        "Debugging: REPRODUCE → ISOLATE → HYPOTHESIZE → TEST → FIX → VERIFY → PREVENT"
      )
      |> maybe_add_hint(
        lower,
        ~r/\bsecurity\b/,
        "Security: apply OWASP Top 10 checklist; parameterize queries, validate inputs, check auth"
      )
      |> maybe_add_hint(
        lower,
        ~r/\bperformance\b/,
        "Performance: profile first with pprof/flamegraph before optimizing; measure the bottleneck"
      )

    {:ok, Map.put(payload, :prompt_hints, hints)}
  end

  defp validate_prompt(payload), do: {:ok, payload}

  defp maybe_add_hint(hints, content, pattern, hint) do
    if Regex.match?(pattern, content), do: [hint | hints], else: hints
  end

  # Hierarchical compaction — emit events at context utilization thresholds
  defp hierarchical_compaction(%{token_count: token_count, token_limit: token_limit} = payload)
       when is_integer(token_count) and is_integer(token_limit) and token_limit > 0 do
    utilization = token_count / token_limit

    cond do
      utilization >= 0.95 ->
        Bus.emit(:system_event, %{
          event: :compaction_critical,
          utilization: utilization,
          token_count: token_count,
          token_limit: token_limit
        })

        {:ok, Map.put(payload, :compaction_state, :critical)}

      utilization >= 0.90 ->
        Bus.emit(:system_event, %{
          event: :compaction_needed,
          utilization: utilization,
          token_count: token_count,
          token_limit: token_limit
        })

        {:ok, Map.put(payload, :compaction_state, :needed)}

      utilization >= 0.80 ->
        Bus.emit(:system_event, %{
          event: :compaction_warning,
          utilization: utilization,
          token_count: token_count,
          token_limit: token_limit
        })

        {:ok, Map.put(payload, :compaction_state, :warning)}

      utilization >= 0.50 ->
        {:ok, Map.put(payload, :compaction_state, :breakpoint)}

      true ->
        {:ok, payload}
    end
  end

  defp hierarchical_compaction(payload), do: {:ok, payload}

  # Auto-format — suggest appropriate formatter for file write/edit tools
  defp auto_format(%{tool_name: tool_name, arguments: %{"path" => path}} = payload)
       when tool_name in ["file_write", "file_edit"] and is_binary(path) do
    ext = Path.extname(path)

    suggestion =
      case ext do
        ".ex" -> "mix format #{path}"
        ".exs" -> "mix format #{path}"
        ".go" -> "gofmt -w #{path}"
        ".ts" -> "prettier --write #{path}"
        ".tsx" -> "prettier --write #{path}"
        ".js" -> "prettier --write #{path}"
        ".jsx" -> "prettier --write #{path}"
        ".py" -> "black #{path}"
        _ -> nil
      end

    if suggestion do
      {:ok, Map.put(payload, :format_suggestion, suggestion)}
    else
      {:ok, payload}
    end
  end

  defp auto_format(payload), do: {:ok, payload}

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

  # Pattern consolidation — detect repeated tool patterns at session end
  defp pattern_consolidation(payload) do
    home = System.user_home!()
    date = Date.utc_today() |> Date.to_string()
    episodes_path = Path.join([home, ".osa", "learning", "episodes", "#{date}-episodes.jsonl"])

    try do
      if File.exists?(episodes_path) do
        counts =
          episodes_path
          |> File.stream!()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&Jason.decode!/1)
          |> Enum.group_by(& &1["tool_name"])
          |> Enum.map(fn {name, entries} -> {name, length(entries)} end)

        Enum.each(counts, fn {tool_name, count} ->
          if count >= 5 do
            Bus.emit(:system_event, %{
              event: :pattern_detected,
              tool_name: tool_name,
              count: count,
              date: date
            })
          end
        end)
      end
    rescue
      e -> Logger.warning("[Hooks] pattern_consolidation failed: #{Exception.message(e)}")
    end

    {:ok, payload}
  end

  # Context optimizer — suggest lazy loading after 20 tools loaded this session
  defp context_optimizer(payload) do
    # ETS counter — no global GC pressure on hot path
    count = :ets.update_counter(:osa_hooks_counters, :tools_loaded, {2, 1})

    if count > 20 do
      hint =
        "Context optimizer: #{count} tools loaded this session. Consider lazy loading — only require tools when needed to preserve context window."

      {:ok, Map.put(payload, :optimize_context, hint)}
    else
      {:ok, payload}
    end
  end

  # ── Error Recovery Suggestions ──────────────────────────────────

  @error_patterns [
    {~r/file.*not found/i, "Check file path exists. Try listing the directory first."},
    {~r/permission denied/i, "Check file permissions. May need elevated access."},
    {~r/syntax error/i, "Review the code for syntax issues. Check matching brackets/quotes."},
    {~r/import.*error|module.*not found/i,
     "Missing dependency. Check package.json/mix.exs/go.mod."},
    {~r/type.*error/i, "Type mismatch. Check function signatures and variable types."},
    {~r/timeout/i, "Operation timed out. Try with a longer timeout or smaller input."},
    {~r/connection.*refused/i, "Service not running. Check if the server is started."},
    {~r/out of memory/i, "Memory exhausted. Process data in smaller chunks."}
  ]

  defp suggest_recovery(error) do
    Enum.find_value(
      @error_patterns,
      "Investigate the error and try an alternative approach.",
      fn {pattern, suggestion} ->
        if Regex.match?(pattern, error), do: suggestion
      end
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp count_hooks(state) do
    state.hooks |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  defp update_metrics(state, event, elapsed_us, result) do
    event_metrics = Map.get(state.metrics, event, %{calls: 0, total_us: 0, blocks: 0})

    blocks =
      case result do
        {:blocked, _} -> event_metrics.blocks + 1
        _ -> event_metrics.blocks
      end

    updated = %{
      calls: event_metrics.calls + 1,
      total_us: event_metrics.total_us + elapsed_us,
      blocks: blocks,
      avg_us: div(event_metrics.total_us + elapsed_us, event_metrics.calls + 1)
    }

    %{state | metrics: Map.put(state.metrics, event, updated)}
  end
end
