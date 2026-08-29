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
      %{
        name: "session_announce",
        event: :session_start,
        priority: 10,
        handler: &session_announce/1,
        opts: []
      },
      %{
        name: "session_cleanup",
        event: :session_end,
        priority: 90,
        handler: &session_cleanup/1,
        opts: []
      },
      %{
        name: "memory_consolidate",
        event: :session_end,
        priority: 80,
        handler: &memory_consolidate/1,
        opts: []
      },

      # ── pre_tool_use ───────────────────────────────────────────────
      %{
        name: "spend_guard",
        event: :pre_tool_use,
        priority: 8,
        handler: &spend_guard/1,
        opts: []
      },
      %{
        name: "security_check",
        event: :pre_tool_use,
        priority: 10,
        handler: &security_check/1,
        opts: []
      },
      %{
        name: "read_before_write",
        event: :pre_tool_use,
        priority: 12,
        handler: &read_before_write/1,
        opts: []
      },
      %{
        name: "mcp_cache",
        event: :pre_tool_use,
        priority: 15,
        handler: &mcp_cache_pre/1,
        opts: []
      },

      # ── post_tool_use ──────────────────────────────────────────────
      %{
        name: "track_files_read",
        event: :post_tool_use,
        priority: 5,
        handler: &track_files_read/1,
        opts: []
      },
      %{
        name: "mcp_cache_post",
        event: :post_tool_use,
        priority: 15,
        handler: &mcp_cache_post/1,
        opts: []
      },
      %{
        name: "cost_tracker",
        event: :post_tool_use,
        priority: 25,
        handler: &cost_tracker/1,
        opts: []
      },
      %{
        name: "vault_auto_checkpoint",
        event: :post_tool_use,
        priority: 80,
        handler: &vault_auto_checkpoint/1,
        opts: []
      },
      %{
        name: "telemetry",
        event: :post_tool_use,
        priority: 90,
        handler: &telemetry_hook/1,
        opts: []
      },
      %{
        name: "episodic_recorder",
        event: :post_tool_use,
        priority: 90,
        handler: &episodic_recorder/1,
        opts: []
      },
      %{
        name: "learning_observer",
        event: :post_tool_use,
        priority: 95,
        handler: &learning_observer/1,
        opts: []
      },

      # ── post_tool_use_failure ──────────────────────────────────────
      %{
        name: "failure_learning_observer",
        event: :post_tool_use_failure,
        priority: 95,
        handler: &learning_observer/1,
        opts: []
      },

      # ── compaction ─────────────────────────────────────────────────
      %{
        name: "compact_observer_pre",
        event: :pre_compact,
        priority: 50,
        handler: &compact_observer/1,
        opts: []
      },
      %{
        name: "compact_observer_post",
        event: :post_compact,
        priority: 50,
        handler: &compact_observer/1,
        opts: []
      },

      # ── post_response ──────────────────────────────────────────────
      %{
        name: "save_transcript",
        event: :post_response,
        priority: 85,
        handler: &save_transcript/1,
        opts: []
      },
      %{
        name: "auto_save_session",
        event: :post_response,
        priority: 95,
        handler: &auto_save_session/1,
        opts: []
      },
      %{
        name: "auto_skill_creator",
        event: :post_response,
        priority: 96,
        handler: &auto_skill_creator/1,
        opts: []
      },
      %{
        name: "episodic_turn_recorder",
        event: :post_response,
        priority: 88,
        handler: &episodic_turn_recorder/1,
        opts: []
      }
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
    e ->
      Logger.warning("[hooks] session_announce failed: #{Exception.message(e)}")
      {:ok, payload}
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

  # Cost tracker — DORMANT BY MEASUREMENT, and deliberately refuses to bill.
  #
  # This is a registered `:post_tool_use` hook, so it runs after every tool
  # call. It used to call `Budget.record_cost/5` — the COARSE path, which
  # re-prices raw token counts against the ledger's own provider table — on any
  # payload carrying `:tokens_in`/`:tokens_out`.
  #
  # Measured: the only `:post_tool_use` payload the loop constructs
  # (`Loop.ToolExecutor`, `post_payload = %{tool_name, result, duration_ms,
  # session_id}`) has neither key, and it is the only dispatch site for the
  # event outside the external shell/HTTP hook bridges. So the branch has never
  # fired. That is the ONLY reason it has not corrupted anything.
  #
  # If it ever did fire it would double-bill: LLM usage is already recorded
  # exactly once by `Loop.Accounting.record/2`, which prices it with
  # `Pricing.cost/2` and bridges the RESULT via `Budget.record_priced_cost/5`.
  # A second, differently-priced write for the same tokens lands in the same
  # daily/monthly ledger `/cost` prints — and `$/task` is a published number
  # now, so a latent second billing path is not acceptable to leave armed.
  #
  # The hook stays registered (it is part of the post-hook contract and asserted
  # by `hooks_test`/`hooks_ets_test`) but it no longer writes to the ledger. A
  # payload that does carry token counts is a NEW producer that must go through
  # the priced path, so it is surfaced loudly rather than silently billed.
  def cost_tracker(%{tool_name: name, result: _result} = payload) do
    tokens_in = Map.get(payload, :tokens_in, 0)
    tokens_out = Map.get(payload, :tokens_out, 0)

    if is_number(tokens_in) and is_number(tokens_out) and tokens_in + tokens_out > 0 do
      Logger.warning(
        "[cost_tracker] post_tool_use payload for #{inspect(name)} carried token counts " <>
          "(in=#{tokens_in} out=#{tokens_out}) — NOT billed. LLM usage is recorded exactly " <>
          "once by Loop.Accounting.record/2 via Budget.record_priced_cost/5; billing here " <>
          "too would double-count it in the ledger /cost prints. Route the new producer " <>
          "through Loop.Accounting instead."
      )
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
             "[Read-before-write] You're modifying #{path}, and this session has neither " <>
               "read nor written it — so you have no basis for its current content. " <>
               "Call file_read on #{path} once before this first edit. You do NOT need to " <>
               "read it again after your own successful edits; if the file changes under " <>
               "you, the edit is rejected and says so."
           )}
        end
      end
    else
      {:ok, payload}
    end
  end

  def read_before_write(payload), do: {:ok, payload}

  # Track files whose current content the model has a basis for — the input to
  # the read-before-write NUDGE (advisory only; enforcement is `FileState` +
  # `DriftGuard`, which are untouched by this list).
  #
  # `file_write` and `file_edit` are in the list because AUTHORING a file is a
  # basis for its contents just as reading it is. Without them, measured on a
  # scripted work session: write a file, then edit it, and the nudge fires —
  # "You're modifying <path> without reading it first" — about a file the model
  # composed itself one turn earlier. It fires again on the following edit
  # (the cap is 2 per file), so a create-then-refine sequence, which is the
  # normal shape of building an artefact, was told twice to go and read back
  # something it already held. That is the read→edit→read→edit rhythm being
  # *instructed*, and it is instructed on no evidence at all.
  #
  # This weakens no guarantee. A stale edit is still rejected — `FileState`
  # compares on-disk `{mtime, size}` against the recorded read/write and
  # `DriftGuard` cross-checks a content fingerprint, both of which record on
  # write already. Verified in the same session probe: an external writer
  # touching the file between edits is still refused with the stale-view
  # message, and an edit to a file this session has neither read nor written is
  # still refused outright.
  def track_files_read(
        %{tool_name: tool_name, arguments: args, session_id: sid, result: result} = payload
      )
      when tool_name in ["file_read", "dir_list", "glob", "file_write", "file_edit"] and
             is_binary(result) and
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
    e ->
      Logger.warning("[hooks] learning_observer failed: #{Exception.message(e)}")
      {:ok, payload}
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
    e ->
      Logger.warning("[hooks] episodic_recorder failed: #{Exception.message(e)}")
      {:ok, payload}
  end

  def episodic_recorder(payload), do: {:ok, payload}

  # Durable episodic recorder — on each completed assistant turn, persist a
  # distilled task attempt (task + heuristic outcome + Reflexion-style
  # reflection) into the long-term EpisodicStore tier via the memory
  # coordinator. Best-effort; skips subagent sessions and empty turns.
  def episodic_turn_recorder(%{session_id: sid, input: input, response: response} = payload)
      when is_binary(sid) do
    task = to_string(input) |> String.trim()

    cond do
      String.starts_with?(sid, "agent:") ->
        {:ok, payload}

      task == "" ->
        {:ok, payload}

      true ->
        resp = to_string(response)
        {outcome, reflection} = classify_turn(resp, Map.get(payload, :tools_used, []))

        event = %{
          kind: :episode,
          task: String.slice(task, 0, 200),
          outcome: outcome,
          reflection: reflection,
          tags: derive_tags(Map.get(payload, :tools_used, [])),
          tools: Map.get(payload, :tools_used, []) |> Enum.map(&to_string/1) |> Enum.uniq()
        }

        OptimalSystemAgent.Agent.Memory.Coordinator.remember(sid, event)
        {:ok, payload}
    end
  rescue
    e ->
      Logger.warning("[hooks] episodic_turn_recorder failed: #{Exception.message(e)}")
      {:ok, payload}
  end

  def episodic_turn_recorder(payload), do: {:ok, payload}

  # Heuristic outcome + reflection for a completed turn. Cheap and LLM-free:
  # failure signals in the response text downgrade the outcome.
  defp classify_turn(response, tools_used) do
    down = String.downcase(response)

    failure? =
      Enum.any?(
        [
          "i hit an error",
          "i couldn't",
          "i could not",
          "failed to",
          "unable to",
          "i wasn't able"
        ],
        &String.contains?(down, &1)
      )

    tool_count = tools_used |> Enum.uniq() |> length()

    outcome = if failure?, do: "failure", else: "success"

    reflection =
      cond do
        failure? ->
          "Turn reported a problem; response: " <> String.slice(response, 0, 140)

        tool_count > 0 ->
          "Completed using #{tool_count} tool type(s); " <> String.slice(response, 0, 120)

        true ->
          "Answered directly: " <> String.slice(response, 0, 140)
      end

    {outcome, reflection}
  end

  defp derive_tags(tools_used) do
    tools_used
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  # Session-end consolidation — promote recurring successful episodes into the
  # semantic skill library (Mem0 extract-on-write). Best-effort.
  def memory_consolidate(%{session_id: sid} = payload) when is_binary(sid) do
    unless String.starts_with?(sid, "agent:") do
      OptimalSystemAgent.Agent.Memory.Coordinator.consolidate(sid)
    end

    {:ok, payload}
  rescue
    _ -> {:ok, payload}
  end

  def memory_consolidate(payload), do: {:ok, payload}

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

  # Save transcript — persist the ASSISTANT turn only. The user turn is
  # persisted at ingestion by TurnPipeline.persist_user_turn/2 (store-at-
  # source, Claude Code pattern): saving it here again would double-write
  # every prompt, and the old code effectively saved the assistant's text
  # under role "user" because :input was mis-derived from the merged
  # message list. Memory auto-extraction moved to ingestion with it.
  # `response` is the fully accumulated streamed final text from ReactLoop.
  #
  # The `turn_*_tokens` fields carry the per-turn token delta the caller
  # (`Loop.run_and_reply/1`) computed by diffing `Loop.Accounting`'s running
  # session totals across the turn. Without them the `tokens` column was written
  # as a literal 0 on every row.
  def save_transcript(%{session_id: sid, response: response} = payload)
      when is_binary(sid) do
    alias OptimalSystemAgent.Store.SessionTranscript

    tokens = turn_tokens(payload)

    try do
      if is_binary(response) and response != "" do
        SessionTranscript.save_turn(sid, "assistant", response, tokens: tokens)
      end
    rescue
      _ -> :ok
    end

    {:ok, payload}
  end

  def save_transcript(payload), do: {:ok, payload}

  # Tokens billed for one turn — ALL FOUR counters `Loop.Accounting` tracks, not
  # just input + output.
  #
  # Cache reads are not a rounding error here. With prompt caching actually
  # working (v1.0.56), a repeat turn's prompt arrives almost entirely as
  # `cache_read_input_tokens` and `input_tokens` collapses to the short uncached
  # tail. Summing only input + output would report a large turn as a small one,
  # and would make the column read LOWER the better the cache performed — the
  # opposite of what it is for. Cache writes are billed too (at a premium), so
  # they count as well.
  #
  # Missing, nil or negative fields contribute 0, so a caller that computes no
  # delta behaves exactly as before rather than crashing the hook.
  defp turn_tokens(payload) do
    [
      :turn_input_tokens,
      :turn_output_tokens,
      :turn_cache_creation_tokens,
      :turn_cache_read_tokens
    ]
    |> Enum.map(fn key ->
      case Map.get(payload, key) do
        n when is_integer(n) and n > 0 -> n
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

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
    # OFF by default. This scraped a "skill" from every 5+ tool turn and named it
    # after the raw user message, so low-signal chatter ("nice", "okay", "what can
    # u do") became junk skills that then flooded the skill-discovery reminders.
    # Real skills are created deliberately via save_skill/create_skill. Opt in
    # with `config :optimal_system_agent, auto_skill_capture: true` only if you
    # want (and then it still needs a proper quality gate, tracked separately).
    if auto_skill_capture_enabled?() and is_binary(sid) and
         not String.starts_with?(sid, "agent:") do
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

  defp auto_skill_capture_enabled? do
    Application.get_env(:optimal_system_agent, :auto_skill_capture, false)
  end
end
