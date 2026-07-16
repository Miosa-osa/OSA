defmodule OptimalSystemAgent.Agent.Hooks.Handlers do
  @moduledoc """
  Concrete **built-in hook handlers** for the agent lifecycle.

  This module holds the actual business logic that runs on hook events. It is
  deliberately separated from the dispatch engine
  (`OptimalSystemAgent.Agent.Hooks.Dispatch`): the engine decides *how* hooks
  run, this module decides *what* they do. Add a new built-in behaviour here;
  add new execution semantics in the engine.

  `builtins/0` returns the registry of built-in handlers. Each entry is a map of
  `%{name, event, priority, handler, opts}` and is installed at startup by the
  `OptimalSystemAgent.Agent.Hooks` facade.

  ## Lifecycle events covered

    * `:session_start`  — announce a new session (audit trail)
    * `:session_end`    — clean up per-session ETS state
    * `:pre_tool_use`   — spend guard, security check, MCP cache, read-nudge
    * `:post_tool_use`  — file tracking, MCP cache fill, cost, telemetry,
                          learning, episodic memory, vault checkpoint
    * `:post_tool_use_failure` — record tool failures for learning
    * `:pre_compact` / `:post_compact` — observe context compaction
    * `:user_prompt_submit` — (extension point; user hooks attach here)
    * `:subagent_start` / `:subagent_stop` — (extension point)
    * `:post_response`  — save transcript, auto-save session, skill capture

  Each handler follows the return protocol documented in `Dispatch`.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  @metrics_table :osa_hooks_metrics

  # ── Registry of built-in handlers ──────────────────────────────────

  @doc "The list of built-in hooks installed at startup."
  @spec builtins() :: [map()]
  def builtins do
    [
      # ── Session lifecycle ──────────────────────────────────────────
      %{name: "session_announce", event: :session_start, priority: 10,
        handler: &session_announce/1, opts: []},
      %{name: "session_cleanup", event: :session_end, priority: 90,
        handler: &session_cleanup/1, opts: []},

      # ── pre_tool_use ───────────────────────────────────────────────
      %{name: "spend_guard", event: :pre_tool_use, priority: 8,
        handler: &spend_guard/1, opts: []},
      %{name: "security_check", event: :pre_tool_use, priority: 10,
        handler: &security_check/1, opts: []},
      %{name: "read_before_write", event: :pre_tool_use, priority: 12,
        handler: &read_before_write/1, opts: []},
      %{name: "mcp_cache", event: :pre_tool_use, priority: 15,
        handler: &mcp_cache_pre/1, opts: []},

      # ── post_tool_use ──────────────────────────────────────────────
      %{name: "track_files_read", event: :post_tool_use, priority: 5,
        handler: &track_files_read/1, opts: []},
      %{name: "mcp_cache_post", event: :post_tool_use, priority: 15,
        handler: &mcp_cache_post/1, opts: []},
      %{name: "cost_tracker", event: :post_tool_use, priority: 25,
        handler: &cost_tracker/1, opts: []},
      %{name: "vault_auto_checkpoint", event: :post_tool_use, priority: 80,
        handler: &vault_auto_checkpoint/1, opts: []},
      %{name: "telemetry", event: :post_tool_use, priority: 90,
        handler: &telemetry_hook/1, opts: []},
      %{name: "episodic_recorder", event: :post_tool_use, priority: 90,
        handler: &episodic_recorder/1, opts: []},
      %{name: "learning_observer", event: :post_tool_use, priority: 95,
        handler: &learning_observer/1, opts: []},

      # ── post_tool_use_failure ──────────────────────────────────────
      %{name: "failure_learning_observer", event: :post_tool_use_failure, priority: 95,
        handler: &learning_observer/1, opts: []},

      # ── compaction ─────────────────────────────────────────────────
      %{name: "compact_observer_pre", event: :pre_compact, priority: 50,
        handler: &compact_observer/1, opts: []},
      %{name: "compact_observer_post", event: :post_compact, priority: 50,
        handler: &compact_observer/1, opts: []},

      # ── post_response ──────────────────────────────────────────────
      %{name: "save_transcript", event: :post_response, priority: 85,
        handler: &save_transcript/1, opts: []},
      %{name: "auto_save_session", event: :post_response, priority: 95,
        handler: &auto_save_session/1, opts: []},
      %{name: "auto_skill_creator", event: :post_response, priority: 96,
        handler: &auto_skill_creator/1, opts: []}
    ]
  end

  # ── Session lifecycle ──────────────────────────────────────────────

  # Session start — announce for audit/telemetry. Never blocks.
  def session_announce(%{session_id: sid} = payload) do
    Bus.emit(:system_event, %{
      event: :session_start,
      session_id: sid,
      channel: Map.get(payload, :channel),
      timestamp: DateTime.utc_now()
    })

    {:ok, payload}
  rescue
    _ -> {:ok, payload}
  end

  def session_announce(payload), do: {:ok, payload}

  # Session cleanup — remove all ETS entries for the session when it ends.
  def session_cleanup(%{session_id: sid} = payload) do
    try do
      :ets.match_delete(:osa_files_read, {{sid, :_}, :_})
      :ets.match_delete(:osa_files_read, {{sid, :nudge_count, :_}, :_})
    rescue
      ArgumentError -> :ok
    end

    {:ok, payload}
  end

  def session_cleanup(payload), do: {:ok, payload}

  # ── Security / budget ──────────────────────────────────────────────

  # Security check — basic dangerous command blocking.
  def security_check(%{tool_name: "shell_execute", arguments: %{"command" => cmd}} = payload) do
    dangerous_patterns = [~r/rm\s+-rf\s+\//, ~r/:(){ :|:& };:/, ~r/mkfs/, ~r/dd\s+.*of=\/dev/]

    if Enum.any?(dangerous_patterns, &Regex.match?(&1, cmd)) do
      {:block, "Blocked potentially dangerous command"}
    else
      {:ok, payload}
    end
  end

  def security_check(payload), do: {:ok, payload}

  # Spend guard — check budget limits before tool execution.
  def spend_guard(payload) do
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

  # ── Cost / telemetry ───────────────────────────────────────────────

  # Cost tracker — record actual API costs after tool use.
  def cost_tracker(%{tool_name: _name, result: _result} = payload) do
    try do
      provider = Map.get(payload, :provider, "unknown")
      model = Map.get(payload, :model, "unknown")
      tokens_in = Map.get(payload, :tokens_in, 0)
      tokens_out = Map.get(payload, :tokens_out, 0)
      session_id = Map.get(payload, :session_id, "unknown")

      if tokens_in > 0 or tokens_out > 0 do
        OptimalSystemAgent.Budget.record_cost(provider, model, tokens_in, tokens_out, session_id)
      end
    catch
      :exit, _ -> :ok
    end

    {:ok, payload}
  end

  def cost_tracker(payload), do: {:ok, payload}

  # Telemetry collection.
  def telemetry_hook(%{tool_name: name, duration_ms: ms} = payload) do
    Bus.emit(:system_event, %{
      event: :tool_telemetry,
      tool_name: name,
      duration_ms: ms,
      timestamp: DateTime.utc_now()
    })

    {:ok, payload}
  end

  def telemetry_hook(payload), do: {:ok, payload}

  # ── Read-before-write ──────────────────────────────────────────────

  # Nudge when file_edit/file_write targets an existing unread file. Does NOT
  # block — adds a :nudge to the payload.
  def read_before_write(%{tool_name: tool_name, arguments: args, session_id: sid} = payload)
      when tool_name in ["file_edit", "file_write"] do
    path = args["path"]

    if is_binary(path) and File.exists?(path) do
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

  def read_before_write(payload), do: {:ok, payload}

  # Track files read — record paths after successful file_read/dir_list/glob.
  def track_files_read(
        %{tool_name: tool_name, arguments: args, session_id: sid, result: result} = payload
      )
      when tool_name in ["file_read", "dir_list", "glob"] and is_binary(result) and
             not (result == "") do
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

  def track_files_read(payload), do: {:ok, payload}

  # ── Vault checkpoint ───────────────────────────────────────────────

  # Save vault state every N tool calls (currently a no-op counter).
  def vault_auto_checkpoint(%{session_id: sid} = payload) when is_binary(sid) do
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

    _ = count
    {:ok, payload}
  end

  def vault_auto_checkpoint(payload), do: {:ok, payload}

  # ── Learning / memory ──────────────────────────────────────────────

  # SICA learning observer — record tool outcomes for pattern learning.
  # Registered for both :post_tool_use and :post_tool_use_failure.
  def learning_observer(%{tool_name: tool_name, result: result} = payload) do
    duration_ms = Map.get(payload, :duration_ms)

    {type, error_message, snippet} =
      cond do
        is_binary(Map.get(payload, :error)) ->
          {:failure, payload.error, nil}

        is_binary(result) and
            (String.starts_with?(result, "Error:") or String.starts_with?(result, "Blocked:")) ->
          {:failure, result, nil}

        true ->
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
  rescue
    _ -> {:ok, payload}
  end

  def learning_observer(payload), do: {:ok, payload}

  # Episodic memory recorder — log tool use events into ETS for context injection.
  def episodic_recorder(%{tool_name: tool_name, result: result} = payload) do
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

  def episodic_recorder(payload), do: {:ok, payload}

  # ── Compaction observer ────────────────────────────────────────────

  # Emit a telemetry event around context compaction (pre and post).
  def compact_observer(payload) do
    Bus.emit(:system_event, %{
      event: :context_compaction,
      phase: Map.get(payload, :phase, :unknown),
      session_id: Map.get(payload, :session_id, "unknown"),
      tokens_before: Map.get(payload, :tokens_before),
      tokens_after: Map.get(payload, :tokens_after),
      tokens_saved: Map.get(payload, :tokens_saved),
      severity: Map.get(payload, :severity),
      timestamp: DateTime.utc_now()
    })

    {:ok, payload}
  rescue
    _ -> {:ok, payload}
  end

  # ── MCP schema cache ───────────────────────────────────────────────

  # pre_tool_use: inject cached schema if fresh (< 1 hour).
  def mcp_cache_pre(%{tool_name: tool_name} = payload) when is_binary(tool_name) do
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

  def mcp_cache_pre(payload), do: {:ok, payload}

  # post_tool_use: store schema from result.
  def mcp_cache_post(%{tool_name: tool_name, result: result} = payload)
      when is_binary(tool_name) and is_binary(result) do
    if String.starts_with?(tool_name, "mcp_") do
      cache_key = {__MODULE__, :mcp_schema, tool_name}
      :persistent_term.put(cache_key, %{schema: result, cached_at: DateTime.utc_now()})
    end

    {:ok, payload}
  end

  def mcp_cache_post(payload), do: {:ok, payload}

  # ── post_response ──────────────────────────────────────────────────

  # Save transcript — persist user input and assistant response.
  def save_transcript(%{session_id: sid, input: input, response: response} = payload)
      when is_binary(sid) do
    alias OptimalSystemAgent.Store.SessionTranscript

    try do
      if is_binary(input) and input != "" do
        SessionTranscript.save_turn(sid, "user", input)

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

  def save_transcript(payload), do: {:ok, payload}

  # Auto-save session state for resume.
  def auto_save_session(%{session_id: sid} = payload) when is_binary(sid) do
    try do
      OptimalSystemAgent.Agent.SessionPersistence.auto_save(sid)
    rescue
      _ -> :ok
    end

    {:ok, payload}
  end

  def auto_save_session(payload), do: {:ok, payload}

  # Auto skill creator — fire-and-forget skill generation from complex tasks.
  def auto_skill_creator(
        %{tools_used: tools, total_tool_calls: count, input: input, session_id: sid} = payload
      )
      when is_list(tools) and is_integer(count) and count >= 5 do
    if is_binary(sid) and not String.starts_with?(sid, "agent:") do
      Task.start(fn ->
        try do
          tool_names = tools |> Enum.map(&to_string/1) |> Enum.uniq()

          pattern = %{
            id: "auto:#{sid}:#{count}",
            description: "Auto-captured: #{String.slice(to_string(input), 0, 80)}",
            trigger: String.slice(to_string(input), 0, 40),
            response:
              "Tools used: #{Enum.join(tool_names, ", ")}\n\nOriginal task: #{String.slice(to_string(input), 0, 200)}",
            category: "automation",
            tags: Enum.join(tool_names, ","),
            occurrences: 5
          }

          OptimalSystemAgent.Memory.SkillGenerator.generate_from_pattern(pattern)
        rescue
          _ -> :ok
        end
      end)
    end

    {:ok, payload}
  end

  def auto_skill_creator(payload), do: {:ok, payload}
end
