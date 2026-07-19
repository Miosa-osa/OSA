defmodule OptimalSystemAgent.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles permission tier enforcement, hook pipeline invocation,
  parallel tool dispatch, and read-before-write nudge injection.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.RenderBridge
  alias OptimalSystemAgent.Agent.Loop.ToolArgValidator
  alias OptimalSystemAgent.Agent.Safety.DestructiveWarning
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Permissions.AutoClassifier
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

  # Edit/write tools auto-approved in :accept_edits permission mode. Narrower
  # than @workspace_tools: file_delete/file_move and git stay gated (ask/tier)
  # because they are destructive beyond a single-file edit.
  @edit_tools ~w(file_write file_edit multi_file_edit file_create)

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
          {:blocked, message} ->
            message

          :allow ->
            run_tool(tool_call, state)

          {:ask, request_id, summary} ->
            # DEFAULT 'ask' mode: park the executing process, emit a
            # permission_required event, and resume once the TUI dialog POSTs a
            # decision to /api/v1/permissions/respond (or the wait aborts).
            case await_permission(tool_call, state, request_id, summary) do
              :allow -> run_tool(tool_call, state)
              {:blocked, message} -> message
              # Reject-with-steer: the user's clarify text becomes the tool
              # result verbatim, feeding their correction back into the turn.
              {:steer, text} -> text
            end
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
  # `:allow` (fall through to run_tool/2), `{:blocked, message}` (the message
  # becomes the tool result verbatim), or `{:ask, request_id, summary}` (park
  # the executing process and wait for an interactive decision — DEFAULT ask
  # mode). Public (@doc false) so the permission stack can be unit-tested.
  #
  # Order matters and is preserved exactly:
  #   1. NON-BYPASSABLE circuit-breaker — a hard blocklist of catastrophic
  #      commands (fork bombs, dd to block devices, mkfs, force-push to
  #      protected branches, …). Evaluated ONCE, before everything else, so it
  #      applies in EVERY permission mode — including :overdrive — and cannot be
  #      bypassed.
  #   1b. saved DENY rules — evaluated before every permission-mode
  #      short-circuit (CC permissions.ts step-1 ordering), so an explicit deny
  #      rule holds even in :overdrive/:bypass and :accept_edits.
  #   2. permission_mode gate (higher-level selector, this commit):
  #        :overdrive    → allow all (full auto), circuit-breaker aside
  #        :plan         → deny mutating tools (read-only planning)
  #        :accept_edits → auto-allow edit/write tools, else fall to tier+ask
  #        :ask (default)→ current tier + Guardian, then interactive prompt for
  #                        mutating tools not covered by a saved rule
  #   3. permission tier gate / subagent gate / auto-mode Guardian (unchanged)
  #   4. saved-rule check + interactive ask (maybe_ask/2)
  @doc false
  def approve_tool_call(tool_call, state) do
    circuit_breaker =
      OptimalSystemAgent.Agent.Safety.DangerousCommands.blocked?(tool_call)

    # Resolve the mode from the sticky store FIRST (it is the durable, disk-backed
    # record of what the operator last chose in the TUI), falling back to the live
    # loop state. This is what makes overdrive actually hold: a mode set before the
    # loop existed, a loop recreated fresh, or the whole daemon restarted (wiping
    # the live state) all leave the store correct, so the check no longer silently
    # reverts to :ask and prompt while the TUI shows "overdrive on".
    mode =
      OptimalSystemAgent.Agent.PermissionMode.get(Map.get(state, :session_id)) ||
        Map.get(state, :permission_mode, :ask)

    # Bypass-immune safety paths (.git internals, OSA settings/permission
    # files, shell rc). Computed once, consumed by step 1c below.
    safety_ask =
      Permissions.bypass_immune_ask(tool_call.name, Map.get(tool_call, :arguments) || %{})

    cond do
      match?({:blocked, _}, circuit_breaker) ->
        {:blocked, reason} = circuit_breaker

        Logger.error(
          "[loop] CIRCUIT-BREAKER blocked #{tool_call.name}: #{reason} (mode=#{mode}, tier=#{state.permission_tier}, session: #{state.session_id})"
        )

        {:blocked,
         "Blocked: #{reason} (hard safety limit — not overridable in any permission mode)"}

      # Step 1b (CC permissions.ts step-1 ordering): an explicit saved DENY rule
      # beats every mode short-circuit — overdrive/bypass and accept_edits
      # included. Same message as the maybe_ask/2 deny branch.
      saved_rule_denies?(tool_call) ->
        {:blocked, "Blocked: #{tool_call.name} is denied by a saved permission rule"}

      # Step 1c — bypass-immune safety ask: mutating writes to .git/ internals,
      # OSA settings/permission files, and shell startup files ALWAYS prompt —
      # overdrive/accept_edits included — and saved allow rules or session
      # grants cannot skip it (CC parity: rule-based checks still run under
      # bypassPermissions). Plan mode and tier denials still win: a tool the
      # tier forbids stays blocked rather than becoming promptable.
      is_binary(safety_ask) and mode != :plan and
          permission_tier_allows?(state.permission_tier, tool_call.name) ->
        safety_prompt(tool_call, safety_ask)

      # Overdrive / bypass (full auto): everything past the circuit-breaker runs
      # — EXCEPT a subagent's structural tool restrictions. A subagent inherits
      # overdrive from its parent (so it can actually work on its :internal,
      # non-interactive channel), but the subagent tool boundary (no recursion
      # via delegate/create_agent, no user-facing tools, per-agent denylist) is a
      # safety structure, not a permission prompt — it must hold even in
      # overdrive. Enforced here so overdrive never opens a hole the tier gate
      # would otherwise close.
      mode in [:overdrive, :bypass] ->
        if state.permission_tier == :subagent and
             not subagent_tool_allowed?(tool_call.name, state) do
          {:blocked, "Blocked: this agent role does not have access to #{tool_call.name}"}
        else
          :allow
        end

      # Plan mode: read-only. Any tool that is not in the read-only set would
      # change state, so it is denied while planning.
      mode == :plan and not permission_tier_allows?(:read_only, tool_call.name) ->
        {:blocked,
         "Blocked: plan mode is read-only — #{tool_call.name} would change state. " <>
           "Switch to auto-edit, ask, or overdrive (full auto) to make changes."}

      # Accept-edits: single-file edit/write tools are auto-approved; anything
      # else (shell, delete/move, git, risky tools) falls through to tier + ask.
      mode == :accept_edits and tool_call.name in @edit_tools ->
        :allow

      true ->
        approve_by_tier(tool_call, state)
    end
  end

  # Saved DENY rules are consulted before any permission-mode short-circuit
  # (step 1b in approve_tool_call/2). :allow/:ask results fall through — allow
  # short-circuits stay mode-governed; only an explicit deny is absolute.
  defp saved_rule_denies?(tool_call) do
    args = Map.get(tool_call, :arguments) || %{}
    Permissions.check(tool_call.name, args) == :deny
  end

  # Existing tier + subagent + auto-Guardian gate. Returns `:allow` |
  # `{:blocked, msg}` | `{:ask, ...}` — on a tier "allow", defers to maybe_ask/2
  # for saved-rule enforcement and the interactive prompt.
  defp approve_by_tier(tool_call, state) do
    tier_decision =
      cond do
        not permission_tier_allows?(state.permission_tier, tool_call.name) ->
          Logger.warning(
            "[loop] Permission denied: tier=#{state.permission_tier} blocked #{tool_call.name} (session: #{state.session_id})"
          )

          {:blocked,
           "Blocked: #{state.permission_tier} mode — #{tool_call.name} is not permitted at this permission level"}

        state.permission_tier == :subagent and not subagent_tool_allowed?(tool_call.name, state) ->
          Logger.warning(
            "[loop] Subagent tool denied: #{tool_call.name} blocked by agent definition (session: #{state.session_id})"
          )

          {:blocked, "Blocked: this agent role does not have access to #{tool_call.name}"}

        state.permission_tier == :auto ->
          # Auto-mode: gate the call through the safety Guardian. An {:allow}
          # falls through to maybe_ask/2 (defense in depth: saved rules still
          # apply, but auto-mode never opens the interactive prompt).
          case OptimalSystemAgent.Agent.Safety.Guardian.review(tool_call, state) do
            {:block, reason} -> {:blocked, "Blocked: #{reason}"}
            {:pause, reason} -> {:blocked, "Blocked (auto-mode paused): #{reason}"}
            {:allow} -> :tier_ok
          end

        true ->
          # DOCUMENTED BOUNDARY (finding-14): in non-:auto tiers the only hard
          # danger gate is the DangerousCommands circuit-breaker in the
          # :pre_tool_use security hook, which is SHELL-COMMAND-SHAPED — it
          # inspects @shell_tools / @delete_tools argument strings. It does NOT
          # semantically vet remote mcp_* or custom/plugin tools whose danger
          # lives server-side. Those are trusted at the :full tier by design;
          # gate them via an explicit per-server allowlist if that is a concern.
          :tier_ok
      end

    case tier_decision do
      {:blocked, _} = blocked -> blocked
      :tier_ok -> maybe_ask(tool_call, state)
    end
  end

  # The tier permitted the call. Enforce saved allow/deny/ask rules (with
  # provenance) and path-scope checks, then decide whether to prompt.
  #
  # Read-only tools never prompt (no side effects). For mutating tools:
  #   - a deny rule blocks (message carries rule + source provenance)
  #   - an allow rule short-circuits — unless the write is out of workspace
  #     scope and the rule is only tool-level (a content rule that names the
  #     path is honored; a blanket tool allow does not cover foreign paths)
  #   - an explicit ask rule or an out-of-scope path always prompts (the
  #     session-scoped grant cannot skip it)
  #   - otherwise the session grant short-circuits, else PARK and ask; when
  #     interactive prompts are disabled (headless channels) FAIL CLOSED —
  #     the explicit `:non_interactive_permission_bypass` config restores the
  #     old auto-allow (config/test.exs and deliberate unattended runs).
  defp maybe_ask(tool_call, state) do
    if permission_tier_allows?(:read_only, tool_call.name) do
      :allow
    else
      args = Map.get(tool_call, :arguments) || %{}
      {decision, meta} = Permissions.check_detailed(tool_call.name, args)
      oos_path = Permissions.out_of_scope_write(tool_call.name, args)

      cond do
        decision == :deny ->
          {:blocked,
           "Blocked: #{tool_call.name} is denied by a saved permission rule" <>
             provenance_suffix(meta)}

        decision == :allow and (oos_path == nil or content_rule?(meta)) ->
          :allow

        true ->
          reason = ask_reason(decision, meta, oos_path)
          explicit_ask_rule? = decision == :ask and is_binary(meta.rule)

          cond do
            not interactive_permissions?() ->
              non_interactive_decision(tool_call)

            explicit_ask_rule? or oos_path != nil ->
              {:ask, PermissionBroker.new_request_id(), permission_summary(tool_call, reason)}

            PermissionBroker.session_allowed?(state.session_id, tool_call.name) ->
              :allow

            true ->
              # Auto-permission classifier (opt-in, default off): before surfacing
              # the DEFAULT ask, let the classifier downgrade a provably-safe /
              # model-approved call to :allow. It can ONLY downgrade this default
              # ask — deny/catastrophic/safety asks and explicit ask rules never
              # reach here — and it fails safe to the prompt on any doubt.
              case AutoClassifier.maybe_allow(tool_call, state) do
                :allow ->
                  :allow

                _ ->
                  {:ask, PermissionBroker.new_request_id(),
                   permission_summary(tool_call, reason)}
              end
          end
      end
    end
  end

  defp content_rule?(%{rule: rule}) when is_binary(rule),
    do: Permissions.parse_rule(rule).content != nil

  defp content_rule?(_), do: false

  defp provenance_suffix(%{rule: rule, source: source}) when is_binary(rule),
    do: " (#{rule}, #{source} settings)"

  defp provenance_suffix(_), do: ""

  defp ask_reason(:allow, _meta, oos) when is_binary(oos),
    do: "path is outside the workspace and allowed directories: #{oos}"

  defp ask_reason(:ask, %{rule: rule, source: source}, _oos) when is_binary(rule),
    do: "an ask rule requires confirmation: #{rule} (#{source} settings)"

  defp ask_reason(_decision, _meta, oos) when is_binary(oos),
    do: "path is outside the workspace and allowed directories: #{oos}"

  defp ask_reason(_, _, _), do: nil

  # Bypass-immune safety paths prompt even in overdrive; on channels that
  # cannot prompt this fails closed (the explicit test/unattended bypass
  # config in non_interactive_decision/1 is honored).
  defp safety_prompt(tool_call, reason) do
    if interactive_permissions?() do
      {:ask, PermissionBroker.new_request_id(),
       permission_summary(tool_call, "Safety check (not bypassable): #{reason}")}
    else
      non_interactive_decision(tool_call)
    end
  end

  defp saved_rule_for(tool_call),
    do: Permissions.suggested_rule(tool_call.name, Map.get(tool_call, :arguments) || %{})

  defp interactive_permissions? do
    Application.get_env(:optimal_system_agent, :interactive_permissions, true)
  end

  # FAIL CLOSED (WS1): a mutating tool that would prompt, on a channel that
  # cannot prompt, is auto-rejected instead of silently allowed. The explicit
  # `:non_interactive_permission_bypass` opt-out restores the old auto-allow —
  # set only in config/test.exs and for deliberately unattended deployments.
  defp non_interactive_decision(tool_call) do
    if Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false) do
      :allow
    else
      {:blocked,
       "Blocked: #{tool_call.name} requires interactive approval, but this channel " <>
         "cannot prompt — auto-rejected (permissions fail closed). Save an allow rule " <>
         "for this tool, or run it from an interactive session."}
    end
  end

  # Enriched permission_required payload (CC parity): kind, old/new content
  # for diff rendering, destructive-command warning, prompt reason, and
  # structured rule/directory suggestions.
  defp permission_summary(tool_call, reason) do
    args = Map.get(tool_call, :arguments) || %{}
    kind = permission_kind(tool_call.name)
    {old_content, new_content} = permission_diff(tool_call.name, args)

    warning =
      if kind == "bash",
        do: DestructiveWarning.warning_for(Map.get(args, "command") || Map.get(args, "code")),
        else: nil

    %{
      tool: tool_call.name,
      args: tool_call_hint(args),
      # Human-facing target: the ACTUAL thing this call acts on (the skill name,
      # the shell command, the file path, the delegate task) so the dialog can
      # say "Allow skill: lavish?" instead of the generic "Allow use_skill?".
      # nil falls back to the bare tool name in the UI.
      target: permission_target(tool_call.name, args),
      kind: kind,
      old_content: old_content,
      new_content: new_content,
      warning: warning,
      reason: reason,
      suggestions: permission_suggestions(tool_call.name, args)
    }
  end

  # The meaningful, human-facing target of a permission request, per tool. Keeps
  # a nil fallback (the dialog shows the tool name) for tools with no obvious
  # single target. Shell/skill/path/delegate are surfaced verbatim (trimmed).
  @target_limit 80
  defp permission_target(name, args) do
    cond do
      name == "use_skill" ->
        label_for(args["skill_name"] || args["skill"], "skill: ")

      name in OptimalSystemAgent.Agent.Safety.DangerousCommands.shell_tools() ->
        clip(args["command"] || args["code"])

      name in ["file_edit", "multi_file_edit"] ->
        label_for(file_target(args), "edit ")

      name in ["file_write", "file_create"] ->
        label_for(file_target(args), "write ")

      name in ["file_delete"] ->
        label_for(file_target(args), "delete ")

      name in ["file_move"] ->
        label_for(file_target(args), "move ")

      name in ["delegate", "create_agent"] ->
        label_for(args["task"] || args["agent"] || args["subagent"] || args["role"], "task: ")

      true ->
        nil
    end
  end

  defp file_target(args), do: args["path"] || args["file_path"] || args["target"]

  defp label_for(value, prefix) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> prefix <> clip(trimmed)
    end
  end

  defp label_for(_, _), do: nil

  defp clip(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(~r/\s+/, " ") do
      "" -> nil
      s when byte_size(s) > @target_limit -> binary_part(s, 0, @target_limit) <> "…"
      s -> s
    end
  end

  defp clip(_), do: nil

  defp permission_kind(name) do
    cond do
      name in OptimalSystemAgent.Agent.Safety.DangerousCommands.shell_tools() -> "bash"
      name in ["file_edit", "multi_file_edit"] -> "file_edit"
      name in ["file_write", "file_create"] -> "file_write"
      name in ["file_delete", "file_move"] -> "file_delete"
      name in ["web_fetch", "web_search"] -> "fetch"
      String.starts_with?(name, "mcp__") -> "mcp"
      true -> "other"
    end
  end

  # Old/new content for the dialog's diff viewport. Edits carry their own
  # old/new strings; whole-file writes diff against the current disk content.
  @permission_diff_limit 20_000
  defp permission_diff(name, %{"old_string" => old, "new_string" => new})
       when name in ["file_edit", "multi_file_edit"] and is_binary(old) and is_binary(new) do
    {truncate_content(old), truncate_content(new)}
  end

  defp permission_diff(name, %{"path" => path, "content" => content})
       when name in ["file_write", "file_create"] and is_binary(path) and is_binary(content) do
    old =
      case File.read(path) do
        {:ok, existing} -> existing
        _ -> ""
      end

    {truncate_content(old), truncate_content(content)}
  end

  defp permission_diff(_name, _args), do: {nil, nil}

  defp truncate_content(bin) when byte_size(bin) > @permission_diff_limit,
    do: binary_part(bin, 0, @permission_diff_limit) <> "\n… (truncated)"

  defp truncate_content(bin), do: bin

  defp permission_suggestions(name, args) do
    rule_suggestion = [
      %{
        type: "addRules",
        behavior: "allow",
        rule: Permissions.suggested_rule(name, args),
        destination: "localSettings"
      }
    ]

    dir_suggestion =
      case Permissions.out_of_scope_write(name, args) do
        nil -> []
        path -> [%{type: "addDirectories", directories: [Path.dirname(path)]}]
      end

    rule_suggestion ++ dir_suggestion
  end

  # Emit `permission_required` (mirrors the plan_proposed emit path) then block
  # on PermissionBroker until the client responds / the wait aborts, and map the
  # decision onto an execution outcome.
  defp await_permission(tool_call, state, request_id, summary) do
    emit_permission_required(state, request_id, tool_call, summary)

    case PermissionBroker.await(state.session_id, request_id) do
      {:ok, %{decision: decision, note: note}} ->
        apply_permission_decision(decision, note, tool_call, state)

      {:error, :timeout} ->
        {:blocked,
         "Blocked: permission request for #{tool_call.name} timed out with no response — not run"}

      {:error, :cancelled} ->
        {:blocked, "Blocked: #{tool_call.name} cancelled before approval"}
    end
  end

  @doc false
  # Map a normalized permission decision onto an execution outcome. Public
  # (@doc false) so the allow-always / reject-with-steer wiring is unit-testable
  # without driving a full HTTP round-trip.
  #   :allow_once    → run once
  #   :allow_session → remember for the session, run
  #   :allow_always  → persist an allow rule (future calls short-circuit), run
  #   :deny          → block once
  #   :deny_always   → persist a deny rule, block
  #   :clarify       → reject-with-steer: feed the note back into the turn
  def apply_permission_decision(decision, note, tool_call, state) do
    case decision do
      :allow_once ->
        :allow

      :allow_session ->
        PermissionBroker.allow_for_session(state.session_id, tool_call.name)
        :allow

      :allow_always ->
        # Persist a SCOPED rule, not a whole-tool allow: shell calls save a
        # command-prefix rule (e.g. shell_execute(npm test:*)); other tools
        # keep the tool-level rule.
        tool_call |> saved_rule_for() |> Permissions.save_rule(:allow_always)
        :allow

      :deny ->
        {:blocked, "Blocked: you declined to run #{tool_call.name}"}

      :deny_always ->
        tool_call |> saved_rule_for() |> Permissions.save_rule(:deny_always)
        {:blocked, "Blocked: #{tool_call.name} denied and saved as a standing rule"}

      :clarify ->
        case String.trim(note || "") do
          "" -> {:blocked, "Blocked: you asked to reconsider #{tool_call.name}"}
          steer -> {:steer, steer}
        end
    end
  end

  defp emit_permission_required(state, request_id, tool_call, summary) do
    # `args` is the flat human hint STRING (the TUI deserializes it as a
    # string — the previous nested summary map failed serde parsing and the
    # dialog never opened via this path); enriched fields ride at top level.
    payload = %{
      type: :system_event,
      event: :permission_required,
      session_id: state.session_id,
      request_id: request_id,
      tool: tool_call.name,
      args: Map.get(summary, :args, ""),
      target: Map.get(summary, :target),
      kind: Map.get(summary, :kind, "other"),
      old_content: Map.get(summary, :old_content),
      new_content: Map.get(summary, :new_content),
      warning: Map.get(summary, :warning),
      reason: Map.get(summary, :reason),
      suggestions: Map.get(summary, :suggestions, [])
    }

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event, payload}
    )

    Bus.emit(
      :system_event,
      Map.delete(payload, :type),
      Observability.annotate(state, source: "agent.tool_executor")
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
        tool_call.id,
        state.session_id
      )

    # Run post_tool_use hooks SYNC and CONSUME their results (WS1/CC parity):
    # a :rewrite_output replaces the tool result the model sees, injected
    # context is appended to it, and a hook block surfaces its reason as
    # feedback. The tool already ran, so hooks-unavailable is non-fatal here.
    post_payload = %{
      tool_name: tool_call.name,
      result: result_str,
      duration_ms: tool_duration_ms,
      session_id: state.session_id
    }

    result_str = consume_post_hooks(result_str, post_payload)

    # Fire distinct failure hook if tool errored. Computed on the CLEAN
    # post-hook result, BEFORE cross-cutting reminders are appended, so an
    # appended "<system-reminder>" can never flip the Error:/Blocked: prefix
    # test or the grounded-verification success signal below.
    tool_failed =
      String.starts_with?(result_str, "Error:") or String.starts_with?(result_str, "Blocked:")

    # Cross-cutting <system-reminder> pipeline (grok src/reminders parity):
    # surface finished background tasks / subagents, a SKILL.md near a touched
    # path, and post-edit diagnostics — deduped per session, non-fatal. Both
    # the model-facing tool message and the returned observation carry these.
    result_str = maybe_append_reminders(result_str, tool_call, state)

    if tool_failed do
      run_hooks_async(:post_tool_use_failure, Map.put(post_payload, :error, result_str))
    end

    # P1-3: record this call in the grounded-verification evidence ledger. A
    # successful write marks a changed file; a successful check (shell build/
    # test, re-read of the file, grep referencing it) is the evidence the gate
    # requires before the model may declare completion. `not tool_failed` is
    # the exit-0 / no-error signal.
    OptimalSystemAgent.Agent.Loop.VerificationEvidence.record(state.session_id, %{
      tool: tool_call.name,
      args: Map.get(tool_call, :arguments) || %{},
      success: not tool_failed
    })

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

  # PostToolUse hook consumption (CC parity). The tool has already run, so a
  # hook cannot un-run it — but its verdict shapes what the model sees:
  #   {:blocked, reason}              → append the reason as hook feedback
  #   {:ok, %{result: rewritten}}     → a :rewrite_output replaced the result
  #   {:ok, %{injected_context: cs}}  → append injected context lines
  #   {:error, :hooks_unavailable}    → keep the original result (non-critical)
  defp consume_post_hooks(result_str, post_payload) do
    case run_hooks(:post_tool_use, post_payload) do
      {:blocked, reason} ->
        result_str <> "\n\n[post_tool_use hook blocked this result: #{reason}]"

      {:ok, final} when is_map(final) ->
        rewritten =
          case Map.get(final, :result) do
            r when is_binary(r) -> r
            _ -> result_str
          end

        case Map.get(final, :injected_context, []) do
          ctx when is_list(ctx) and ctx != [] ->
            notes = ctx |> Enum.filter(&is_binary/1) |> Enum.join("\n")
            if notes == "", do: rewritten, else: rewritten <> "\n\n[hook context]\n" <> notes

          _ ->
            rewritten
        end

      _ ->
        result_str
    end
  end

  # Cross-cutting reminder append (primitive #18). Thin, fault-isolated
  # delegate to Agent.Reminders so a reminder failure can never break a tool
  # observation. Skips subagent turns: reminders about background completions /
  # skills are for the user-facing loop, not a delegated worker.
  defp maybe_append_reminders(result_str, tool_call, state) do
    if Map.get(state, :permission_tier) == :subagent do
      result_str
    else
      OptimalSystemAgent.Agent.Reminders.append(result_str, tool_call, state)
    end
  rescue
    e ->
      Logger.debug("[loop] reminder append failed (non-critical): #{inspect(e)}")
      result_str
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
  # use_skill: surface the skill name (not the arg keys) so the live activity
  # feed and permission dialog show which skill is running.
  defp tool_call_hint(%{"skill_name" => s}) when is_binary(s), do: s

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

  # Execute a tool with transient-retry, fallback support, and metadata capture.
  #
  # P0-2: a bounded, jittered retry wraps the dispatch so a CLEARLY-TRANSIENT
  # failure (timeout, connection reset, EAGAIN, 429/5xx, ephemeral lock) is
  # retried up to 3 attempts before surfacing — instead of killing a long
  # build/test/run on a one-off hiccup. SEMANTIC failures (old_string not
  # found, ambiguous, validation, permission denied) are never retried; those
  # are handled by the deterministic {:error, reason} path below.
  defp execute_tool(tool_name, enriched_args) do
    session_id = Map.get(enriched_args, "__session_id__")

    result =
      OptimalSystemAgent.Agent.Loop.ToolRetry.run(
        fn -> Tools.execute(tool_name, enriched_args) end,
        tool: tool_name,
        session_id: session_id
      )

    handle_execute_result(result, tool_name, enriched_args)
  end

  defp handle_execute_result(result, tool_name, enriched_args) do
    case result do
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
