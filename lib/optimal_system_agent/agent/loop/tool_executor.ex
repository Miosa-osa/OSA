defmodule OptimalSystemAgent.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles permission tier enforcement, hook pipeline invocation,
  parallel tool dispatch, and read-before-write nudge injection.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.RenderBridge
  alias OptimalSystemAgent.Agent.Loop.ToolArgValidator
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability

  # Tools allowed in :read_only mode (no side-effects, no writes)
  @read_only_tools ~w(
    file_read file_glob dir_list file_grep file_search
    memory_recall session_search semantic_search
    code_symbols web_fetch web_search list_skills
    list_dir read_file grep_search
  )

  # Additional tools unlocked in :workspace mode (local writes only)
  @workspace_tools ~w(
    file_write file_edit multi_file_edit file_create file_delete file_move
    git task_write memory_write memory_save download create_skill
  )

  # Tools ALWAYS blocked for subagents — prevents recursion, shared state
  # corruption, and user-facing actions from non-user-facing processes.
  @subagent_blocked_tools ~w(delegate ask_user create_skill create_agent memory_save)

  @doc false
  def permission_tier_allows?(:full, _tool), do: true
  # :auto (unattended auto-mode) allows every tool at the tier gate; the safety
  # Guardian (policy classifier) decides block/pause per call downstream.
  def permission_tier_allows?(:auto, _tool), do: true
  def permission_tier_allows?(:read_only, tool), do: tool in @read_only_tools

  def permission_tier_allows?(:workspace, tool),
    do: tool in (@read_only_tools ++ @workspace_tools)

  def permission_tier_allows?(:subagent, tool) do
    tool not in @subagent_blocked_tools
  end

  def permission_tier_allows?(_, _), do: true

  @doc """
  Check subagent permission with per-agent allowlist/denylist overrides.

  Called from execute_tool_call when the Loop state carries per-agent
  tool restrictions from the AGENT.md definition.
  """
  def subagent_tool_allowed?(tool, state) do
    allowed = Map.get(state, :allowed_tools)
    blocked = Map.get(state, :blocked_tools, [])

    cond do
      # Always-blocked takes precedence
      tool in @subagent_blocked_tools -> false
      # Per-agent denylist
      is_list(blocked) and tool in blocked -> false
      # Per-agent allowlist (nil = all allowed)
      is_list(allowed) and allowed != [] -> tool in allowed
      # Default: allowed
      true -> true
    end
  end

  @doc """
  Execute a single tool call — used by parallel Task.async_stream.
  Returns {tool_msg, result_str} tuple.

  Thin orchestrator over the three tool-call concerns, invoked in order:

    1. `approve_tool_call/2`  — circuit-breaker + tier + subagent + Guardian policy
    2. `run_tool/2`           — pre_tool_use hook pipeline + actual execution
    3. `finalize_result/5`    — normalize/truncate/image + post hooks + telemetry + events

  The start-of-call telemetry/events fire here (orchestration boundary); the
  end/result events fire inside `finalize_result/5`.
  """
  def execute_tool_call(tool_call, state) do
    # Idempotency + per-step durable write record (primitive #27). On a mid-turn
    # crash+resume, a step whose {session, turn, iteration, tool, args} key was
    # already recorded as completed returns the recorded result WITHOUT
    # re-executing its side effects. Disabled or session-less callers run the
    # tool exactly as before — this wrapper is a pure passthrough then.
    DurableLog.run_once(state, tool_call, fn ->
      arg_hint = tool_call_hint(tool_call.arguments)

      emit_tool_call_start(tool_call, arg_hint, state)

      start_time_tool = System.monotonic_time(:millisecond)

      tool_result =
        case approve_tool_call(tool_call, state) do
          {:blocked, message} -> message
          :allow -> run_tool(tool_call, state)
        end

      finalize_result(tool_call, tool_result, state, arg_hint, start_time_tool)
    end)
  end

  @doc """
  Inject system nudge when file_edit/file_write targeted files that weren't read first.
  Checks the :osa_files_read ETS table for nudge flags set by the read_before_write hook.
  Nudges max 2 times per session per file to prevent doom loops.
  """
  def inject_read_nudges(state, tool_calls) do
    write_tools = Enum.filter(tool_calls, fn tc -> tc.name in ["file_edit", "file_write"] end)

    if write_tools == [] do
      state
    else
      nudged_paths =
        write_tools
        |> Enum.map(fn tc -> tc.arguments["path"] end)
        |> Enum.filter(fn path ->
          is_binary(path) and File.exists?(path) and
            not file_was_read?(state.session_id, path) and
            get_nudge_count(state.session_id, path) < 2
        end)
        |> Enum.uniq()

      if nudged_paths == [] do
        state
      else
        paths_str = Enum.join(nudged_paths, ", ")

        nudge_msg = %{
          role: "system",
          content:
            "[System: You modified #{paths_str} without reading #{if length(nudged_paths) == 1, do: "it", else: "them"} first. " <>
              "Always call file_read before file_edit/file_write on existing files to understand current content.]"
        }

        %{state | messages: state.messages ++ [nudge_msg]}
      end
    end
  rescue
    e ->
      Logger.debug("[loop] inject_read_nudges failed (non-critical): #{inspect(e)}")
      state
  end

  # --- Private helpers ---

  # Emit the start-of-call telemetry + PubSub event pair. Fired once by the
  # orchestrator before approval/execution, so it always precedes the paired
  # :end / :tool_result events emitted from finalize_result/5.
  defp emit_tool_call_start(tool_call, arg_hint, state) do
    Bus.emit(
      :tool_call,
      %{
        name: tool_call.name,
        phase: :start,
        args: arg_hint,
        session_id: state.session_id,
        agent: state.session_id
      },
      Observability.annotate(state, source: "agent.tool_executor")
    )

    # OpenTelemetry GenAI execute_tool span (no-op unless otel_enabled).
    Observability.otel_tool(state, tool_call.name)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :tool_call,
         name: tool_call.name,
         phase: "start",
         args: arg_hint,
         session_id: state.session_id
       }}
    )
  end

  # CONCERN 1 — approval policy.
  #
  # Decides whether the call may proceed, WITHOUT running it. Returns
  # `{:blocked, message}` (the message becomes the tool result verbatim) or
  # `:allow` (fall through to run_tool/2 and the pre_tool_use hook pipeline).
  #
  # Order matters and is preserved exactly:
  #   1. NON-BYPASSABLE circuit-breaker — a hard blocklist of catastrophic
  #      commands (rm -rf /, force-push to protected branches, fork bombs, dd to
  #      block devices, mkfs, DROP DATABASE, curl|sh, …). Evaluated ONCE, before
  #      the tier/guardian cond so it applies in EVERY permission tier —
  #      including :full / bypass — and cannot be bypassed by the auto Guardian.
  #   2. permission tier gate
  #   3. subagent per-agent allow/deny gate
  #   4. auto-mode safety Guardian (a nil review falls through to :allow so the
  #      pre_tool_use hooks still run — defense in depth).
  defp approve_tool_call(tool_call, state) do
    circuit_breaker =
      OptimalSystemAgent.Agent.Safety.DangerousCommands.blocked?(tool_call)

    decision =
      cond do
        match?({:blocked, _}, circuit_breaker) ->
          {:blocked, reason} = circuit_breaker

          Logger.error(
            "[loop] CIRCUIT-BREAKER blocked #{tool_call.name}: #{reason} (tier=#{state.permission_tier}, session: #{state.session_id})"
          )

          "Blocked: #{reason} (hard safety limit — not overridable in any permission tier)"

        not permission_tier_allows?(state.permission_tier, tool_call.name) ->
          Logger.warning(
            "[loop] Permission denied: tier=#{state.permission_tier} blocked #{tool_call.name} (session: #{state.session_id})"
          )

          "Blocked: #{state.permission_tier} mode — #{tool_call.name} is not permitted at this permission level"

        state.permission_tier == :subagent and not subagent_tool_allowed?(tool_call.name, state) ->
          Logger.warning(
            "[loop] Subagent tool denied: #{tool_call.name} blocked by agent definition (session: #{state.session_id})"
          )

          "Blocked: this agent role does not have access to #{tool_call.name}"

        state.permission_tier == :auto ->
          # Auto-mode: gate the call through the safety Guardian. A nil result
          # falls through to the :pre_tool_use hooks below — defense in depth.
          case OptimalSystemAgent.Agent.Safety.Guardian.review(tool_call, state) do
            {:block, reason} -> "Blocked: #{reason}"
            {:pause, reason} -> "Blocked (auto-mode paused): #{reason}"
            {:allow} -> nil
          end

        true ->
          # DOCUMENTED BOUNDARY (finding-14): in non-:auto tiers the only hard
          # danger gate is the DangerousCommands circuit-breaker in the
          # :pre_tool_use security hook, which is SHELL-COMMAND-SHAPED — it
          # inspects @shell_tools / @delete_tools argument strings. It does NOT
          # semantically vet remote mcp_* or custom/plugin tools whose danger
          # lives server-side. Those are trusted at the :full tier by design;
          # gate them via an explicit per-server allowlist if that is a concern.
          nil
      end

    case decision do
      nil -> :allow
      message -> {:blocked, message}
    end
  end

  # CONCERN 2 — execution.
  #
  # Runs schema-validation (REASK on malformed args — single chokepoint for all
  # tools), then the pre_tool_use hook pipeline sync (security_check/spend_guard
  # can block) and then dispatches the tool. Returns the raw tool result: an
  # `{:image, media_type, b64, path}` tuple, a binary, or a "Blocked:"/"Error:"
  # string. Only reached when approve_tool_call/2 returned :allow.
  defp run_tool(tool_call, state) do
    # Validate the model's tool arguments against the tool schema BEFORE running
    # any hook or the tool itself. On invalid/malformed input, hand the model a
    # REASK error (verbatim tool result) so it rewrites the call next step —
    # instead of silently executing with empty (%{}) arguments.
    case ToolArgValidator.validate(tool_call, state) do
      {:reask, message} -> message
      :ok -> run_validated_tool(tool_call, state)
    end
  end

  defp run_validated_tool(tool_call, state) do
    # Run pre_tool_use hooks sync (security_check/spend_guard can block)
    pre_payload = %{
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      session_id: state.session_id
    }

    case run_hooks(:pre_tool_use, pre_payload) do
      {:blocked, reason} ->
        "Blocked: #{reason}"

      {:error, :hooks_unavailable} ->
        # Hooks GenServer is down — fail closed. Never execute a tool when
        # security_check and spend_guard are unreachable.
        Logger.error(
          "[loop] Blocking tool #{tool_call.name} — pre_tool_use hooks unavailable (session: #{state.session_id})"
        )

        "Blocked: security pipeline unavailable"

      {:ok, %{arguments: modified_args} = _modified_payload} ->
        # Hook modified the tool arguments — use the modified version
        enriched_args = Map.put(modified_args, "__session_id__", state.session_id)
        execute_tool(tool_call.name, enriched_args)

      {:inject_message, content} ->
        # Hook wants to inject a system message instead of executing the tool.
        # Store it for the next LLM call via process dict.
        existing = Process.get(:osa_injected_messages, [])
        Process.put(:osa_injected_messages, existing ++ [content])
        # Still execute the tool
        enriched_args = Map.put(tool_call.arguments, "__session_id__", state.session_id)
        execute_tool(tool_call.name, enriched_args)

      _ ->
        # Inject session_id so tools like ask_user can register pending state
        enriched_args = Map.put(tool_call.arguments, "__session_id__", state.session_id)
        execute_tool(tool_call.name, enriched_args)
    end
  end

  # CONCERN 3 — result finalization.
  #
  # Given the raw tool result, does everything downstream of execution:
  # normalize → output budget → post_tool_use (+ failure) hooks → telemetry →
  # end/result Bus + PubSub events → RenderBridge → tool message assembly
  # (image content blocks or truncated text). Returns the {tool_msg, result_str}
  # contract expected by callers.
  defp finalize_result(tool_call, tool_result, state, arg_hint, start_time_tool) do
    max_tool_output_bytes =
      Application.get_env(:optimal_system_agent, :max_tool_output_bytes, 10_240)

    tool_duration_ms = System.monotonic_time(:millisecond) - start_time_tool

    # Normalize result for hooks/events
    result_str =
      case tool_result do
        {:image, _mt, _b64, path} -> "[image: #{path}]"
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    # Apply tool result budget — persist large results to disk
    result_str =
      OptimalSystemAgent.Agent.Loop.ToolResultStorage.apply_budget(
        result_str,
        tool_call.name,
        tool_call.id
      )

    # Run post_tool_use hooks async (cost tracker, telemetry, learning)
    post_payload = %{
      tool_name: tool_call.name,
      result: result_str,
      duration_ms: tool_duration_ms,
      session_id: state.session_id
    }

    run_hooks_async(:post_tool_use, post_payload)

    # Fire distinct failure hook if tool errored
    tool_failed =
      String.starts_with?(result_str, "Error:") or String.starts_with?(result_str, "Blocked:")

    if tool_failed do
      run_hooks_async(:post_tool_use_failure, Map.put(post_payload, :error, result_str))
    end

    # Record telemetry
    try do
      OptimalSystemAgent.Telemetry.Metrics.record_tool(
        tool_call.name,
        tool_duration_ms,
        not tool_failed
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    Bus.emit(
      :tool_call,
      %{
        name: tool_call.name,
        phase: :end,
        duration_ms: tool_duration_ms,
        result_bytes: byte_size(result_str),
        success: not tool_failed,
        args: arg_hint,
        session_id: state.session_id,
        agent: state.session_id
      },
      Observability.annotate(state, source: "agent.tool_executor")
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :tool_call,
         name: tool_call.name,
         phase: "end",
         duration_ms: tool_duration_ms,
         success: true,
         session_id: state.session_id
       }}
    )

    tool_success = !match?({:error, _}, tool_result)
    result_preview = String.slice(result_str, 0, 2000)

    # Retrieve tool metadata (diff data, etc.) if the tool stored any
    tool_metadata = Process.delete(:osa_tool_metadata) || %{}

    tool_result_event =
      %{
        name: tool_call.name,
        result: result_preview,
        result_bytes: byte_size(result_str),
        success: tool_success,
        session_id: state.session_id,
        agent: state.session_id
      }
      |> Map.merge(tool_metadata)

    Bus.emit(:tool_result, tool_result_event, Observability.annotate(state, source: "agent.tool_executor"))

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       Map.merge(
         %{
           type: :tool_result,
           name: tool_call.name,
           result: result_preview,
           success: tool_success,
           session_id: state.session_id
         },
         tool_metadata
       )}
    )

    # Emit structured render payload — additive, never blocks execution.
    RenderBridge.emit(tool_call.name, tool_result, state.session_id)

    # Build tool message — images get structured content blocks.
    # Both branches include `name: tool_call.name` so that on iteration 2+
    # every provider's format_messages/1 can attribute the result back to
    # the exact tool that was called (required by Ollama and OpenAI-compat).
    tool_msg =
      case tool_result do
        {:image, media_type, b64, path} ->
          %{
            role: "tool",
            tool_call_id: tool_call.id,
            name: tool_call.name,
            content: [
              %{type: "text", text: "Image: #{path}"},
              %{type: "image", source: %{type: "base64", media_type: media_type, data: b64}}
            ]
          }

        _ ->
          limit = max_tool_output_bytes

          content =
            if byte_size(result_str) > limit do
              truncated = binary_part(result_str, 0, limit)

              truncated <>
                "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{limit} bytes]"
            else
              result_str
            end

          %{role: "tool", tool_call_id: tool_call.id, name: tool_call.name, content: content}
      end

    {tool_msg, result_str}
  end

  # For file_edit: send full JSON args so TUI can render the diff with
  # old_string/new_string. For other tools: send a short hint.
  defp tool_call_hint(%{"old_string" => _, "new_string" => _} = args) do
    case Jason.encode(args) do
      {:ok, json} -> json
      _ -> Map.get(args, "path", "")
    end
  end

  defp tool_call_hint(%{"action" => "screenshot"}), do: "screenshot"
  defp tool_call_hint(%{"action" => "click", "x" => x, "y" => y}), do: "click (#{x}, #{y})"
  defp tool_call_hint(%{"action" => "click", "target" => t}), do: "click → #{t}"

  defp tool_call_hint(%{"action" => "double_click", "x" => x, "y" => y}),
    do: "double_click (#{x}, #{y})"

  defp tool_call_hint(%{"action" => "type", "text" => t}), do: "type #{String.slice(t, 0, 30)}"
  defp tool_call_hint(%{"action" => "key", "text" => t}), do: "key #{t}"
  defp tool_call_hint(%{"action" => "scroll", "direction" => d}), do: "scroll #{d}"

  defp tool_call_hint(%{"action" => "move_mouse", "x" => x, "y" => y}),
    do: "move_mouse (#{x}, #{y})"

  defp tool_call_hint(%{"action" => "drag", "x" => x, "y" => y}), do: "drag (#{x}, #{y})"
  defp tool_call_hint(%{"action" => a}), do: a

  defp tool_call_hint(%{"command" => cmd}), do: String.slice(cmd, 0, 60)
  defp tool_call_hint(%{"path" => p}), do: p
  defp tool_call_hint(%{"query" => q}), do: String.slice(q, 0, 60)

  defp tool_call_hint(args) when is_map(args) and map_size(args) > 0 do
    args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")
  end

  defp tool_call_hint(_), do: ""

  defp file_was_read?(session_id, path) do
    try do
      case :ets.lookup(:osa_files_read, {session_id, path}) do
        [{_, true}] -> true
        _ -> false
      end
    rescue
      ArgumentError -> false
    end
  end

  defp get_nudge_count(session_id, path) do
    try do
      nudge_key = {session_id, :nudge_count, path}

      case :ets.lookup(:osa_files_read, nudge_key) do
        [{^nudge_key, n}] -> n
        _ -> 0
      end
    rescue
      ArgumentError -> 0
    end
  end

  # Run hooks with fault isolation.
  #
  # Returns {:error, :hooks_unavailable} when the Hooks GenServer is down,
  # rather than {:ok, payload}. This is intentional: pre_tool_use callers
  # MUST fail closed (block execution) when the security pipeline is
  # unreachable. post_tool_use callers may choose to warn and continue.
  defp run_hooks(event, payload) do
    try do
      Hooks.run(event, payload)
    catch
      :exit, reason ->
        Logger.warning("[loop] Hooks GenServer unreachable for #{event} (#{inspect(reason)})")
        {:error, :hooks_unavailable}
    end
  end

  # Async hooks — fire-and-forget for post-event hooks (post_tool_use).
  # Pre-tool hooks stay sync so security_check/spend_guard can block.
  # Logs a warning if the Hooks GenServer is down so the issue is visible,
  # but does not block — post-event side effects are non-critical.
  defp run_hooks_async(event, payload) do
    try do
      Hooks.run_async(event, payload)
    catch
      :exit, reason ->
        Logger.warning(
          "[loop] Hooks GenServer unreachable for async #{event} (#{inspect(reason)})"
        )

        :ok
    end
  end

  # Execute a tool with fallback support and metadata capture.
  defp execute_tool(tool_name, enriched_args) do
    case Tools.execute(tool_name, enriched_args) do
      {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
        {:image, mt, b64, p}

      {:ok, content, metadata} when is_map(metadata) ->
        Process.put(:osa_tool_metadata, metadata)
        content

      {:ok, content} ->
        content

      {:error, reason} ->
        # Only fall back on tool-availability/dispatch failures. A semantic
        # domain error (old_string not found, ambiguous/identical match) means
        # the tool ran and reported a MODEL mistake — retrying a sibling edit
        # tool with the same args is wasted work and risks running a different
        # tool on mismatched args. Return the real error instead.
        if semantic_tool_error?(reason) do
          "Error: #{reason}"
        else
          case Tools.suggest_fallback_tool(tool_name) do
            {:ok, alt_tool} ->
              Logger.info(
                "[loop] Tool '#{tool_name}' failed (#{inspect(reason)}), trying fallback '#{alt_tool}'"
              )

              case Tools.execute(alt_tool, enriched_args) do
                {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
                  {:image, mt, b64, p}

                {:ok, alt_content} ->
                  "[used #{alt_tool} as fallback for #{tool_name}]\n#{alt_content}"

                {:error, _alt_reason} ->
                  "Error: #{reason}"
              end

            :no_alternative ->
              "Error: #{reason}"
          end
        end
    end
  end

  # A semantic/domain tool error (the tool ran and rejected the args) vs. a
  # tool-availability/dispatch failure (unknown tool / tool crashed). We only
  # fall back to a sibling tool for the latter.
  defp semantic_tool_error?(reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason)
    down = String.downcase(text)

    String.contains?(down, [
      "not found in",
      "old_string not found",
      "ambiguous",
      "no match",
      "not unique",
      "identical",
      "already exists",
      "no changes"
    ])
  end
end
