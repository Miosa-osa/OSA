defmodule OptimalSystemAgent.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles permission tier enforcement, hook pipeline invocation,
  parallel tool dispatch, and read-before-write nudge injection.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Attendance
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.Loop.RenderBridge
  alias OptimalSystemAgent.Agent.Loop.ToolArgMetrics
  alias OptimalSystemAgent.Agent.Loop.ToolArgValidator
  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolHint
  alias OptimalSystemAgent.Agent.Safety.DestructiveWarning
  alias OptimalSystemAgent.Agent.Safety.UntrustedContent
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Permissions.AskFlow
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

  def permission_tier_allows?(:read_only, tool),
    do: tool in @read_only_tools and not plugin_tool?(tool)

  def permission_tier_allows?(:workspace, tool),
    do: tool in (@read_only_tools ++ @workspace_tools) and not plugin_tool?(tool)

  def permission_tier_allows?(:subagent, tool) do
    tool not in @subagent_blocked_tools
  end

  def permission_tier_allows?(_, _), do: true

  # Tools contributed by `~/.osa/plugins/*.exs` never satisfy an auto-allow
  # tier, whatever `safety/0` they declare. The tier gate here is name-based,
  # so without this a plugin that got a built-in name past the loader would
  # inherit that name's auto-approval. Plugin tools always reach `maybe_ask/2`.
  defp plugin_tool?(tool) when is_binary(tool) do
    OptimalSystemAgent.Plugins.Loader.plugin_tool_name?(tool)
  rescue
    _ -> false
  end

  defp plugin_tool?(_), do: false

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
      # Skill discovery is part of every agent's task protocol. These read-only
      # meta tools must survive role allowlists or a child can be instructed to
      # select a skill while being structurally unable to inspect one.
      tool in ["skill_view", "list_skills"] -> true
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

  ## NON-FATAL TOOL ERROR contract (Codex `FunctionCallError` parity)

  The whole call is wrapped in `ToolError.run/1`, so NOTHING that happens inside
  — a raising tool, a `throw`, a GenServer-call `:exit`, a broken hook, a
  permission denial, a crash in the durable log — can take the turn down. Every
  failure except an explicit fatal signal is synthesized into a normal,
  model-readable tool result (`"Error: …"`) and the turn CONTINUES.

  Returns `{tool_msg, result_str}`, or `{tool_msg, result_str, {:fatal, msg}}`
  when the failure was fatal (see `ToolError`) and the turn must abort.
  """
  def execute_tool_call(tool_call, state) do
    case ToolError.run(fn -> durable_execute_tool_call(tool_call, state) end) do
      {:ok, result} ->
        result

      # FATAL — the only class that still kills the turn.
      {:fatal, message} ->
        Logger.error(
          "[loop] FATAL tool error in #{tool_call.name}: #{message} (session: #{Map.get(state, :session_id)})"
        )

        ToolError.fatal_result(tool_call, message)

      # RESPOND-TO-MODEL (the default): hand the model the failure text as an
      # ordinary tool result instead of dying.
      {:error, message} ->
        Logger.warning(
          "[loop] Recovered tool failure in #{tool_call.name}: #{message} (session: #{Map.get(state, :session_id)})"
        )

        recovered_result(tool_call, state, message)
    end
  end

  defp durable_execute_tool_call(tool_call, state) do
    # Idempotency + per-step durable write record (primitive #27). On a mid-turn
    # crash+resume, a step whose {session, turn, iteration, tool, args} key was
    # already recorded as completed returns the recorded result WITHOUT
    # re-executing its side effects. Disabled or session-less callers run the
    # tool exactly as before — this wrapper is a pure passthrough then.
    DurableLog.run_once(state, tool_call, fn ->
      arg_hint = tool_call_hint(tool_call.arguments)

      emit_tool_call_start(tool_call, arg_hint, state)

      start_time_tool = System.monotonic_time(:millisecond)

      # Approval + execution run under the two-class contract. A non-fatal
      # failure becomes the tool result text (so finalize_result/5 still emits
      # the :end / :tool_result events, records telemetry and feeds the TUI);
      # a FATAL unwinds past DurableLog.run_once WITHOUT recording the step.
      tool_result =
        case ToolError.run(fn -> approve_and_run(tool_call, state) end) do
          {:ok, result} -> result
          {:error, message} -> ToolError.model_text(message)
          {:fatal, message} -> ToolError.throw_fatal(message)
        end

      finalize_result(tool_call, tool_result, state, arg_hint, start_time_tool)
    end)
  end

  # Approval policy + execution — the part of a tool call that is allowed to
  # fail. Returns the raw tool result term.
  defp approve_and_run(tool_call, state) do
    case approve_tool_call(tool_call, state) do
      {:blocked, message} ->
        # Belt and braces for the contract described on `handler_hard_deny/1`:
        # a refusal MUST be recognisable as one downstream, and the only signal
        # `finalize_result/5` has is this prefix. Normalising here means a new
        # `{:blocked, _}` producer cannot silently re-open the hole.
        prefix_blocked(message)

      :allow ->
        run_tool(tool_call, state)

      {:ask, request_id, summary} ->
        # DEFAULT 'ask' mode: park the executing process, emit a
        # permission_required event, and resume once the TUI dialog POSTs a
        # decision to /api/v1/permissions/respond (or the wait aborts).
        #
        # EVERY outcome here is a model-readable string: a denial's reason, a
        # timeout/cancel notice, or the user's reject-with-steer text. None of
        # them ends the turn — the model reads the reason and picks another
        # route (Codex funnels approval rejections through the same
        # RespondToModel channel).
        case await_permission(tool_call, state, request_id, summary) do
          :allow -> run_tool(tool_call, state)
          {:blocked, message} -> message
          {:steer, text} -> text
        end
    end
  end

  # RESPOND-TO-MODEL recovery: the call blew up somewhere outside the normal
  # result path (durable log, start events, arg hinting, finalize_result). Try
  # to run the real finalization pipeline with the error text so the TUI/SSE
  # still see a :tool_result; if THAT is what is broken, fall back to a bare
  # tool message. Either way the model gets a readable failure and the turn
  # continues.
  defp recovered_result(tool_call, state, message) do
    body = ToolError.model_text(message)

    case ToolError.run(fn ->
           finalize_result(tool_call, body, state, "", System.monotonic_time(:millisecond))
         end) do
      {:ok, result} ->
        result

      _ ->
        {%{role: "tool", tool_call_id: tool_call.id, name: tool_call.name, content: body}, body}
    end
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
            "[System: You modified #{paths_str} without this session having read or written " <>
              "#{if length(nudged_paths) == 1, do: "it", else: "them"} first. " <>
              "Read a file once before your FIRST edit to it. Do not re-read after your own " <>
              "successful edits — you already know what you changed, and if anything else " <>
              "changes the file the next edit is rejected with a stale-view error.]"
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
    arg_bytes = tool_call_arg_bytes(tool_call.arguments)
    arg_hash = tool_call_arg_hash(tool_call.arguments)
    assertions = tool_call_assertions(tool_call.arguments)

    Bus.emit(
      :tool_call,
      %{
        name: tool_call.name,
        # Stable per-call identity. Tools run CONCURRENTLY and every shell call
        # shares the name "shell_execute", so any consumer that pairs
        # start/end/result by NAME shuffles results between cells. Emit the id
        # that already exists for LLM history so the wire can pair exactly.
        tool_call_id: tool_call.id,
        phase: :start,
        args: arg_hint,
        args_bytes: arg_bytes,
        args_hash: arg_hash,
        # The propositions this call wrote down, when it wrote any. See
        # `ToolArgMetrics.assertion_lines/1`: `nil` on every call that is not a
        # write, so the event shape is unchanged for ~90% of the stream.
        assertions: assertions,
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
         tool_call_id: tool_call.id,
         phase: "start",
         args: arg_hint,
         args_bytes: arg_bytes,
         args_hash: arg_hash,
         assertions: assertions,
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
  #   1. circuit-breaker (`DangerousCommands.classify/1`) — evaluated ONCE,
  #      before everything else. Two severity classes:
  #        :catastrophic → NON-BYPASSABLE in every mode, :overdrive included
  #          (rm -rf /, fork bombs, dd to a block device, mkfs, DROP DATABASE).
  #          Unrecoverable destruction; operator intent does not make it safe.
  #        :overridable  → blocked in every mode EXCEPT :overdrive/:bypass
  #          (force-push to a protected branch, curl|sh). Bounded, recoverable
  #          risk that is frequently the literal requested task; overdrive is an
  #          explicit "full auto" statement, and a breaker that refuses it with
  #          no recourse is a defect, not a safety property.
  #      This is the ONLY place that distinction is applied — see
  #      DangerousCommands' moduledoc for the rationale.
  #   1b. saved DENY rules — evaluated before every permission-mode
  #      short-circuit (CC permissions.ts step-1 ordering), so an explicit deny
  #      rule holds even in :overdrive/:bypass and :accept_edits.
  #   2. permission_mode gate (higher-level selector, this commit):
  #        :overdrive    → allow all (full auto), circuit-breaker aside
  #        :plan         → deny mutating tools (read-only planning)
  #        :accept_edits → auto-allow edit/write tools IN-SCOPE and without an
  #                        explicit saved ask rule; an out-of-workspace path or
  #                        an ask rule still prompts (see accept_edits_decision/1);
  #                        anything outside @edit_tools falls to tier+ask
  #        :ask (default)→ current tier + Guardian, then interactive prompt for
  #                        mutating tools not covered by a saved rule
  #   3. permission tier gate / subagent gate / auto-mode Guardian (unchanged)
  #   4. saved-rule check + interactive ask (maybe_ask/2)
  @doc false
  def approve_tool_call(tool_call, state) do
    circuit_breaker =
      OptimalSystemAgent.Agent.Safety.DangerousCommands.classify(tool_call)

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

    # Write-family handler hard path-guard, consulted up front so a write we can
    # never perform is blocked with its real reason instead of being asked and
    # then failing at execute (the "I approved but it says Access denied" bug).
    # Computed once; consumed by step 1b′ below.
    hard_deny = handler_hard_deny(tool_call)

    # Step 1 — the breaker, resolved against the mode. `:ok` here means either
    # nothing matched, or an :overridable pattern matched under overdrive and
    # was consciously waived (logged). Everything else in the cond still runs:
    # a waived breaker match is NOT an automatic allow.
    breaker_decision = enforce_circuit_breaker(circuit_breaker, mode, tool_call, state)

    cond do
      match?({:blocked, _}, breaker_decision) ->
        breaker_decision

      # Step 1b (CC permissions.ts step-1 ordering): an explicit saved DENY rule
      # beats every mode short-circuit — overdrive/bypass and accept_edits
      # included. Same message as the maybe_ask/2 deny branch.
      saved_rule_denies?(tool_call) ->
        {:blocked, "Blocked: #{tool_call.name} is denied by a saved permission rule"}

      # Step 1b′ — the write-family handler's own hard path-guard. A HARD deny
      # (dotfile outside ~/.osa, out-of-allowed-paths, symlink-to-protected)
      # means the write can never succeed in ANY mode — overdrive included — so
      # surface the real reason now instead of prompting for a call the handler
      # will reject. Ordered before the mode short-circuits for exactly that
      # reason: overdrive must not "allow" a write that then fails at execute.
      match?({:blocked, _}, hard_deny) ->
        hard_deny

      # Step 1c — bypass-immune safety ask: mutating writes to .git/ internals,
      # OSA settings/permission files, and shell startup files ALWAYS prompt —
      # overdrive/accept_edits included — and saved allow rules or session
      # grants cannot skip it (CC parity: rule-based checks still run under
      # bypassPermissions). Plan mode and tier denials still win: a tool the
      # tier forbids stays blocked rather than becoming promptable.
      is_binary(safety_ask) and mode != :plan and
          permission_tier_allows?(state.permission_tier, tool_call.name) ->
        safety_prompt(tool_call, safety_ask, state)

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

      # Accept-edits: edit/write tools are auto-approved ONLY within the
      # workspace scope and only absent an explicit saved `ask` rule for this
      # call — CC parity (bypassPermissions still respects rule-based checks
      # and out-of-workspace guards). Anything else (shell, delete/move, git,
      # risky tools) falls through to tier + ask, unchanged.
      mode == :accept_edits and tool_call.name in @edit_tools ->
        accept_edits_decision(tool_call, state)

      true ->
        approve_by_tier(tool_call, state)
    end
  end

  # accept_edits auto-allow, narrowed: a write/edit targeting a path OUTSIDE
  # the workspace/allowed scope, or matching an operator-saved `ask` rule,
  # must still go through the interactive prompt (or fail closed on a
  # non-interactive channel) instead of being silently allowed. A saved DENY
  # rule is already handled earlier (step 1b) and never reaches here.
  defp accept_edits_decision(tool_call, state) do
    args = Map.get(tool_call, :arguments) || %{}
    oos_path = Permissions.out_of_scope_write(tool_call.name, args)
    {decision, meta} = Permissions.check_detailed(tool_call.name, args)
    explicit_ask_rule? = decision == :ask and is_binary(meta.rule)

    cond do
      is_binary(oos_path) ->
        reason = "path is outside the workspace and allowed directories: #{oos_path}"

        if attended?(state) do
          {:ask, PermissionBroker.new_request_id(), permission_summary(tool_call, reason)}
        else
          non_interactive_decision(tool_call, state)
        end

      explicit_ask_rule? ->
        reason = "an ask rule requires confirmation: #{meta.rule} (#{meta.source} settings)"

        if attended?(state) do
          {:ask, PermissionBroker.new_request_id(), permission_summary(tool_call, reason)}
        else
          non_interactive_decision(tool_call, state)
        end

      true ->
        :allow
    end
  end

  # Saved DENY rules are consulted before any permission-mode short-circuit
  # (step 1b in approve_tool_call/2). :allow/:ask results fall through — allow
  # short-circuits stay mode-governed; only an explicit deny is absolute.
  defp saved_rule_denies?(tool_call) do
    args = Map.get(tool_call, :arguments) || %{}
    Permissions.check(tool_call.name, args) == :deny
  end

  # Write-family tools carry their OWN hard path-safety guard inside the handler
  # (dotfile-outside-~/.osa, out-of-allowed-paths, symlink-to-protected). That
  # guard is a HARD deny that runs unconditionally at execute time, in every
  # permission mode. Before this step it was invisible to the approval layer, so
  # a write to e.g. ~/.lavish was ASKED, the operator said yes, and the handler
  # then rejected it anyway — "I approved but it says Access denied." Consult the
  # same guard here, up front, so a write we can never perform is BLOCKED with
  # the real reason instead of being pointlessly prompted (and so overdrive does
  # not "allow" a call that immediately fails). Only tools whose handler exports
  # a pure `check_permissions/2` (the edit family ignores ctx) are consulted; a
  # `{:deny, msg}` becomes a clean block, everything else falls through.
  @path_guarded_writes ~w(file_write file_edit multi_file_edit notebook_edit file_create)
  # Resolve a circuit-breaker verdict against the session's permission mode.
  #
  #   * `:catastrophic` → blocked, always. There is no mode, flag or setting
  #     that permits it; the message says so explicitly so the model stops
  #     retrying variants of the same command.
  #   * `:overridable` under :overdrive/:bypass → WAIVED. Logged at :warning
  #     (not swallowed) with the reason and the mode that authorised it, so the
  #     operator can see in the log exactly what full-auto let through.
  #   * `:overridable` in any other mode → blocked, with the message naming
  #     overdrive as the recourse — the thing the old unconditional breaker
  #     could not do.
  @spec enforce_circuit_breaker(
          OptimalSystemAgent.Agent.Safety.DangerousCommands.classified(),
          atom(),
          map(),
          map()
        ) :: {:blocked, String.t()} | :ok
  defp enforce_circuit_breaker({:blocked, reason, :catastrophic}, mode, tool_call, state) do
    Logger.error(
      "[loop] CIRCUIT-BREAKER blocked #{tool_call.name}: #{reason} " <>
        "(catastrophic, mode=#{mode}, tier=#{state.permission_tier}, session: #{state.session_id})"
    )

    {:blocked, "Blocked: #{reason} (hard safety limit — not overridable in any permission mode)"}
  end

  defp enforce_circuit_breaker({:blocked, reason, :overridable}, mode, tool_call, state)
       when mode in [:overdrive, :bypass] do
    Logger.warning(
      "[loop] CIRCUIT-BREAKER waived for #{tool_call.name}: #{reason} — " <>
        "permitted because mode=#{mode} (full auto) and this rule is recoverable, not " <>
        "catastrophic (tier=#{state.permission_tier}, session: #{state.session_id})"
    )

    :ok
  end

  defp enforce_circuit_breaker({:blocked, reason, :overridable}, mode, tool_call, state) do
    Logger.error(
      "[loop] CIRCUIT-BREAKER blocked #{tool_call.name}: #{reason} " <>
        "(mode=#{mode}, tier=#{state.permission_tier}, session: #{state.session_id})"
    )

    {:blocked,
     "Blocked: #{reason} (safety limit). If this is genuinely what you were asked to do, " <>
       "the operator can permit it by switching to overdrive (full auto)."}
  end

  defp enforce_circuit_breaker(_no_match, _mode, _tool_call, _state), do: :ok

  # The failure marker `finalize_result/5` reads. Idempotent: a message that
  # already declares itself is left alone, so no message is ever double-tagged.
  defp prefix_blocked(message) when is_binary(message) do
    if String.starts_with?(message, "Blocked:") or String.starts_with?(message, "Error:") do
      message
    else
      "Blocked: " <> message
    end
  end

  defp prefix_blocked(message), do: message

  defp handler_hard_deny(tool_call) do
    if tool_call.name in @path_guarded_writes do
      args = Map.get(tool_call, :arguments) || %{}

      # `Code.ensure_loaded?/1` before `function_exported?/2`: without it the
      # answer is `false` for any module not yet loaded, this `with` falls to
      # `_ -> :ok`, and the path guard on a WRITE tool is skipped — a security
      # check failing open, silently, with the resulting write recorded as a
      # clean success by the very instrumentation the comment below describes.
      # Same defect as the `stream_capable?/1` one, on a guard where the
      # consequence is not a slower stream.
      with mod when is_atom(mod) and not is_nil(mod) <- Tools.module_for(tool_call.name),
           true <- Code.ensure_loaded?(mod) and function_exported?(mod, :check_permissions, 2),
           {:deny, msg} <- safe_check_permissions(mod, args) do
        # The handler's message is raw ("Access denied: … is outside allowed
        # paths"). Every other `{:blocked, _}` in this module carries a
        # "Blocked: " prefix, and that prefix is not cosmetic: `finalize_result/5`
        # decides `tool_failed` — and therefore the `success` field on the
        # `tool_call` end and `tool_result` events, the `post_tool_use_failure`
        # hook, and the grounded-verification evidence ledger — by testing for
        # exactly `"Error:"` or `"Blocked:"` at the start of the result text.
        #
        # Without it a denied write was recorded as a SUCCESSFUL tool call,
        # everywhere at once. Measured in a container: `file_write` to a path
        # outside the allowed roots returned the bare `Access denied: …` string
        # and the end event said `success: true`. That is why an entire
        # benchmark route could be crippled by permission denials while every
        # instrument reported a clean run.
        {:blocked, prefix_blocked(msg)}
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  # The edit handlers' check_permissions/2 only read the path/edits args and
  # ignore ctx, so a nil ctx is safe. Fail OPEN on any unexpected shape/raise:
  # this is an early UX guard, not the security boundary — the handler re-runs
  # the identical guard at execute time (defense in depth), so a miss here can
  # never let a denied write through, only fall back to the old ask-then-deny.
  defp safe_check_permissions(mod, args) do
    mod.check_permissions(args, nil)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
            not attended?(state) ->
              non_interactive_decision(tool_call, state)

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
                  {:ask, PermissionBroker.new_request_id(), permission_summary(tool_call, reason)}
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
  defp safety_prompt(tool_call, reason, state) do
    if attended?(state) do
      {:ask, PermissionBroker.new_request_id(),
       permission_summary(tool_call, "Safety check (not bypassable): #{reason}")}
    else
      non_interactive_decision(tool_call, state)
    end
  end

  defp saved_rule_for(tool_call),
    do: Permissions.suggested_rule(tool_call.name, Map.get(tool_call, :arguments) || %{})

  # "Can a human respond on this session right now" — asked, not re-derived.
  # This used to be a private `interactive_permissions?/0` reading an app-env
  # flag, duplicated verbatim here, in `Permissions.AskFlow` and in
  # `Channels.CLI.Session`, defaulting to `true` and never set by anything
  # headless. See `Agent.Attendance`.
  defp attended?(state), do: Attendance.attended?(state)

  # FAIL CLOSED (WS1): a mutating tool that would prompt, on a session where
  # nobody can answer, is auto-rejected instead of silently allowed. The
  # explicit `:non_interactive_permission_bypass` opt-out restores the old
  # auto-allow — set only in config/test.exs and for deliberately unattended
  # deployments.
  #
  # OBSERVABLE: both outcomes are announced above debug. An auto-ALLOW under the
  # bypass is the one that matters most — it is a permission decision taken with
  # no human in it — and it used to be entirely silent.
  defp non_interactive_decision(tool_call, state) do
    sid = if is_map(state), do: Map.get(state, :session_id), else: nil
    why = Attendance.reason(state)

    if Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false) do
      Logger.warning(
        "[permissions] auto-ALLOWED #{tool_call.name} without asking — unattended session " <>
          "(#{why}) and :non_interactive_permission_bypass is set"
      )

      emit_non_interactive(:allow, tool_call.name, sid, why)
      :allow
    else
      Logger.info(
        "[permissions] auto-DENIED #{tool_call.name} — unattended session (#{why}), " <>
          "permissions fail closed"
      )

      emit_non_interactive(:deny, tool_call.name, sid, why)

      {:blocked,
       "Blocked: #{tool_call.name} requires interactive approval, but nobody can answer on " <>
         "this session (#{why}) — auto-rejected (permissions fail closed). Save an allow " <>
         "rule for this tool, or run it from an interactive session."}
    end
  end

  defp emit_non_interactive(outcome, tool, session_id, why) do
    :telemetry.execute(
      [:osa, :permissions, :non_interactive],
      %{count: 1},
      %{outcome: outcome, tool: tool, session_id: session_id, reason: why}
    )
  rescue
    _ -> :ok
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

      name == "multi_file_edit" ->
        multi_file_target(args)

      name in ["file_edit"] ->
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

  # `multi_file_edit`'s args are `%{"edits" => [%{"path" => ...}, ...]}` — no
  # top-level path, so the dialog must name every file explicitly instead of
  # falling back to the bare tool name (which left the operator approving a
  # multi-file mutation blind).
  defp multi_file_target(%{"edits" => edits}) when is_list(edits) and edits != [] do
    paths =
      edits
      |> Enum.map(fn
        %{"path" => p} when is_binary(p) and p != "" -> p
        _ -> nil
      end)
      |> Enum.filter(&is_binary/1)

    case paths do
      [] ->
        nil

      _ ->
        "edit #{length(paths)} file#{if length(paths) == 1, do: "", else: "s"}: " <>
          clip(Enum.join(paths, ", "))
    end
  end

  defp multi_file_target(_), do: nil

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
       when name == "file_edit" and is_binary(old) and is_binary(new) do
    {truncate_content(old), truncate_content(new)}
  end

  # multi_file_edit: no single old/new pair — concatenate each file's
  # old_string/new_string, headed by its path, so the dialog shows what
  # changes in EVERY file instead of the previous {nil, nil} (no diff at all).
  defp permission_diff(name, %{"edits" => edits})
       when name == "multi_file_edit" and is_list(edits) do
    {olds, news} =
      edits
      |> Enum.filter(fn
        %{"path" => p, "old_string" => o, "new_string" => n} ->
          is_binary(p) and is_binary(o) and is_binary(n)

        _ ->
          false
      end)
      |> Enum.map(fn %{"path" => p, "old_string" => o, "new_string" => n} ->
        {"--- #{p}\n#{o}", "+++ #{p}\n#{n}"}
      end)
      |> Enum.unzip()

    case olds do
      [] -> {nil, nil}
      _ -> {truncate_content(Enum.join(olds, "\n\n")), truncate_content(Enum.join(news, "\n\n"))}
    end
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
    # `suggested_rule/2` returns nil when NO honest "always" rule exists for
    # this call — an interpreter/shell prefix (`bash:*` would pre-approve every
    # command run through bash), a bare `rm`, a heredoc, or a compound command.
    # Offer no "always" option at all rather than a rule that looks scoped and
    # is not; a one-time allow is still available.
    rule_suggestion =
      case Permissions.suggested_rule(name, args) do
        nil ->
          []

        rule ->
          [
            %{
              type: "addRules",
              behavior: "allow",
              rule: rule,
              destination: "localSettings"
            }
          ]
      end

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

    case PermissionBroker.await(state.session_id, request_id, state: state) do
      {:ok, %{decision: decision, note: note}} ->
        apply_permission_decision(decision, note, tool_call, state)

      # Belt AND braces. `approve_tool_call/2` already consults `Attendance`
      # before choosing to prompt, so reaching here means attendance ENDED
      # between the decision to ask and the wait (or a caller reached the
      # broker by another route). Either way the answer is the same one the
      # earlier branch would have given — never a park, never a self-approval.
      {:error, :unattended} ->
        non_interactive_decision(tool_call, state)

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
        # keep the tool-level rule. A nil suggestion means no honest "always"
        # rule exists for this command (interpreter/shell prefix, bare rm,
        # heredoc, compound) — allow it ONCE and persist nothing.
        case saved_rule_for(tool_call) do
          nil -> :ok
          rule -> Permissions.save_rule(rule, :allow_always)
        end

        :allow

      :deny ->
        {:blocked, "Blocked: you declined to run #{tool_call.name}"}

      :deny_always ->
        # Deny rules are never over-broad in the dangerous direction, so a nil
        # suggestion falls back to a tool-level deny rather than saving nothing.
        case saved_rule_for(tool_call) do
          nil -> Permissions.save_rule(tool_call.name, :deny_always)
          rule -> Permissions.save_rule(rule, :deny_always)
        end

        {:blocked, "Blocked: #{tool_call.name} denied and saved as a standing rule"}

      :clarify ->
        case String.trim(note || "") do
          "" -> {:blocked, "Blocked: you asked to reconsider #{tool_call.name}"}
          steer -> {:steer, steer}
        end
    end
  end

  @doc false
  # Public (@doc false) so the routing can be asserted against a real PubSub
  # subscriber, which is the only way to prove the event reaches a session other
  # than the one running the tool.
  def emit_permission_required(state, request_id, tool_call, summary) do
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

    # Who is asking. Empty for a top-level session (the lead's own calls are
    # already attributed by context); populated for a subagent so the same
    # dialog, seen from the root session, names the teammate.
    payload = Map.merge(payload, permission_attribution(state.session_id))

    # The request goes to every session that could answer it: the one running
    # the tool, and — when that is a SUBAGENT — the root session the user is
    # actually attached to. See `permission_topics/1`.
    for target <- permission_topics(state.session_id) do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{target}",
        {:osa_event, Map.put(payload, :session_id, target)}
      )
    end

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

  # Attribution for a permission request raised by a subagent: who is asking,
  # so the dialog can say "@researcher wants to run …" instead of presenting a
  # tool call the user never made as if the lead had made it.
  defp permission_attribution(session_id) do
    case RunStore.get(session_id) do
      %{} = run ->
        %{
          agent_id: session_id,
          display_name: Map.get(run, :role) || session_id,
          role: Map.get(run, :role)
        }

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Every session topic a `permission_required` event for `session_id` must reach.

  A subagent runs under its own session id, and this event was published only
  on that id. Nothing is subscribed there: the TUI streams the ROOT session, so
  a teammate that hit a permission prompt emitted into a topic with no readers.
  `PermissionBroker.await/3` then blocked for its full 300s ceiling and returned
  `{:error, :timeout}`, and the tool was skipped with a message only the
  subagent's own transcript ever saw.

  The user's experience of that is a teammate that appears to be working and
  then quietly does less than it was asked, with no prompt, no error, and a
  five-minute stall in the middle.

  So the event is published on the running session AND on each ancestor up to
  the root. `PermissionBroker.respond/2` is keyed by `request_id` alone — not by
  session — so an answer given at the root satisfies the child's wait with no
  further plumbing. Delivery is idempotent per topic (the list is deduped) and
  the running session stays FIRST so a client attached directly to a subagent
  keeps its existing behaviour.
  """
  @spec permission_topics(String.t() | nil) :: [String.t()]
  def permission_topics(session_id) when is_binary(session_id) do
    [session_id | ancestors(session_id, MapSet.new([session_id]), [])]
  rescue
    _ -> [session_id]
  catch
    :exit, _ -> [session_id]
  end

  def permission_topics(_), do: []

  # Walk `parent_session_id` up the RunStore chain. `seen` guards a cycle in the
  # ledger; "unknown"/"" are the sentinel non-parents written at spawn time.
  defp ancestors(id, seen, acc) do
    case RunStore.get(id) do
      %{parent_session_id: parent}
      when is_binary(parent) and parent not in ["", "unknown"] ->
        if MapSet.member?(seen, parent) do
          Enum.reverse(acc)
        else
          ancestors(parent, MapSet.put(seen, parent), [parent | acc])
        end

      _ ->
        Enum.reverse(acc)
    end
  rescue
    _ -> Enum.reverse(acc)
  catch
    :exit, _ -> Enum.reverse(acc)
  end

  # CONCERN 2 — execution.
  #
  # Runs schema-validation (REASK on malformed args — single chokepoint for all
  # tools), then the pre_tool_use hook pipeline sync (security_check/spend_guard
  # can block) and then dispatches the tool. Returns the raw tool result: an
  # `{:image, media_type, b64, path}` tuple, a binary, or a "Blocked:"/"Error:"
  # string. Only reached when approve_tool_call/2 returned :allow.
  defp run_tool(tool_call, state) do
    # This call is approved (a rule, the permission mode, or the operator's own
    # answer to the dialog above). Record it so the handler-level `:ask` tier
    # (`Permissions.AskFlow`, reached via Tools.LegacyAdapter) does not open a
    # SECOND dialog for the same tool_use. Callers that never went through this
    # approval — the MCP dispatcher, Tools.Pipeline, HTTP tool routes, the cron
    # scheduler — carry no mark and still get prompted.
    AskFlow.mark_call_approved(state.session_id, Map.get(tool_call, :id))

    # Validate the model's tool arguments against the tool schema BEFORE running
    # any hook or the tool itself. On invalid/malformed input, hand the model a
    # REASK error (verbatim tool result) so it rewrites the call next step —
    # instead of silently executing with empty (%{}) arguments.
    case ToolArgValidator.validate(tool_call, state) do
      {:reask, message} -> message
      {:ok, validated_call} -> run_validated_tool(validated_call, state)
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
        enriched_args =
          modified_args
          |> Map.put("__session_id__", state.session_id)
          |> Map.put("__tool_use_id__", tool_call.id)
          |> Map.put("__surface__", authority_surface(state))

        execute_tool(tool_call.name, enriched_args)

      _ ->
        # Inject session_id so tools like ask_user can register pending state
        enriched_args =
          tool_call.arguments
          |> Map.put("__session_id__", state.session_id)
          |> Map.put("__tool_use_id__", tool_call.id)
          |> Map.put("__surface__", authority_surface(state))

        execute_tool(tool_call.name, enriched_args)
    end
  end

  defp authority_surface(%{channel: channel}) when channel in [:scheduler, :heartbeat],
    do: "schedule"

  defp authority_surface(_state), do: "osa"

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

    # P1-3: record this call in the grounded-verification evidence ledger. A
    # successful write marks a changed file; a successful check (shell build/
    # test, re-read of the file, grep referencing it) is the evidence the gate
    # requires before the model may declare completion. `not tool_failed` is
    # the exit-0 / no-error signal, computed above on the CLEAN result so an
    # appended "<system-reminder>" can never flip it.
    #
    # This MUST run before `maybe_append_reminders/3`. The test-first nudge is a
    # reminder that reads this ledger, so while recording came second the ledger
    # could not contain the edit the nudge is about: the nudge only ever fired
    # on the NEXT tool call. On the shape it matters most for — edit once, then
    # answer — there is no next tool call, so the cheap one-shot steer was
    # provably never delivered and the expensive completion gate fired instead.
    # That is the "the nudge was never sent" half of the over-firing report.
    OptimalSystemAgent.Agent.Loop.VerificationEvidence.record(state.session_id, %{
      tool: tool_call.name,
      args: Map.get(tool_call, :arguments) || %{},
      success: not tool_failed
    })

    # Cross-cutting <system-reminder> pipeline (grok src/reminders parity):
    # surface finished background tasks / subagents, a SKILL.md near a touched
    # path, and post-edit diagnostics — deduped per session, non-fatal. Both
    # the model-facing tool message and the returned observation carry these.
    result_str = maybe_append_reminders(result_str, tool_call, state)

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

    # Who is at fault when this call failed. `:osa` ONLY when OSA refused a path
    # that is inside the session's own workspace — see
    # `Permissions.denial_fault_owner/3`. nil otherwise (including on success).
    #
    # Without this a tool-level denial was attributable to nobody: the existing
    # `owner` split lives on TURN errors (`Providers.ErrorCatalog.fault_owner/1`)
    # and a denial is not a turn error, it is a result the model reads. A
    # benchmark run where OSA's own scope resolution broke three of three tasks
    # therefore reported a 0.0% harness fault rate.
    fault_owner =
      if tool_failed do
        Permissions.denial_fault_owner(
          tool_call.name,
          Map.get(tool_call, :arguments) || %{},
          result_str
        )
      end

    if fault_owner == :osa do
      Logger.error(
        "[loop] HARNESS FAULT — #{tool_call.name} was denied for a path INSIDE the session " <>
          "workspace (#{OptimalSystemAgent.Workspace.Cwd.get()}). This is OSA's own scope " <>
          "resolution disagreeing with itself, not a model error: #{String.slice(result_str, 0, 300)}"
      )
    end

    Bus.emit(
      :tool_call,
      %{
        name: tool_call.name,
        tool_call_id: tool_call.id,
        phase: :end,
        duration_ms: tool_duration_ms,
        result_bytes: byte_size(result_str),
        success: not tool_failed,
        fault_owner: fault_owner,
        args: arg_hint,
        # Same faithful pair as the :start event. Carried on BOTH phases
        # because an analysis that scans for completed calls (it needs
        # `success` / `duration_ms`, which only exist here) would otherwise
        # be forced back onto the display hint — the exact substitution that
        # produced the withdrawn 43.5%-duplicate and 62-byte-median figures.
        args_bytes: tool_call_arg_bytes(Map.get(tool_call, :arguments)),
        args_hash: tool_call_arg_hash(Map.get(tool_call, :arguments)),
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
         tool_call_id: tool_call.id,
         phase: "end",
         duration_ms: tool_duration_ms,
         # NOT a literal. This broadcast is what the TUI's SSE stream carries
         # (SessionRoutes `GET /:id/stream` subscribes to this exact topic), so
         # a hard-coded `true` labelled every failed tool call a success on
         # screen — the sibling Bus.emit above already computed the real value.
         success: not tool_failed,
         fault_owner: fault_owner,
         # This broadcast is the SSE stream the bench driver writes out as
         # `osa-events.jsonl`, so the faithful pair has to be here, not only
         # on the Bus.emit sibling above — the file is what every post-hoc
         # analysis actually reads.
         args_bytes: tool_call_arg_bytes(Map.get(tool_call, :arguments)),
         args_hash: tool_call_arg_hash(Map.get(tool_call, :arguments)),
         session_id: state.session_id
       }}
    )

    # The :tool_result pair MUST agree with the :tool_call pair above. It did
    # not: `!match?({:error, _}, tool_result)` tested a shape that cannot reach
    # here. Every error is normalised to an `"Error: "` / `"Blocked: "` STRING
    # by `handle_execute_result/3` (or by the `{:blocked, msg}` approval branch)
    # long before `finalize_result/5` is called, so the match never succeeded
    # and `success` was a constant `true` — for every failed tool call, denials
    # included. Two events, computed two ways, disagreeing on every failure, and
    # the one that was always-true is the one a permission denial surfaced on.
    tool_success = not tool_failed
    result_preview = String.slice(result_str, 0, 2000)

    # Retrieve tool metadata (diff data, etc.) if the tool stored any
    tool_metadata = Process.delete(:osa_tool_metadata) || %{}

    tool_result_event =
      %{
        name: tool_call.name,
        tool_call_id: tool_call.id,
        result: result_preview,
        result_bytes: byte_size(result_str),
        success: tool_success,
        fault_owner: fault_owner,
        session_id: state.session_id,
        agent: state.session_id
      }
      |> Map.merge(tool_metadata)

    Bus.emit(
      :tool_result,
      tool_result_event,
      Observability.annotate(state, source: "agent.tool_executor")
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       Map.merge(
         %{
           type: :tool_result,
           name: tool_call.name,
           tool_call_id: tool_call.id,
           result: result_preview,
           success: tool_success,
           fault_owner: fault_owner,
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
          content = spill_or_truncate(result_str, max_tool_output_bytes, tool_call)

          %{
            role: "tool",
            tool_call_id: tool_call.id,
            name: tool_call.name,
            content: fence_untrusted(tool_call.name, content)
          }
      end

    {tool_msg, result_str}
  end

  @doc """
  Cap a tool result at `limit` bytes WITHOUT losing the tail.

  This is the LAST cut before the result becomes a context message, and it was
  the only one with no way back: everything past `limit` was dropped and the
  model was told solely how many bytes it would never see.

  `ToolResultStorage.apply_budget/4` runs earlier and does offload-with-a-
  reference, but it does not cover this cut. It is bypassed or outrun whenever:

    * `verbose` is set — `apply_budget/4` returns the full result untouched by
      design, and this cut then amputated it anyway;
    * a `post_tool_use` hook rewrites or appends to the result AFTER the budget
      pass, so the message can exceed `limit` without the storage layer ever
      seeing the final bytes;
    * the offload write itself fails, in which case `apply_budget/4` falls back
      to its own head-only truncation with no file behind it;
    * the two read the same `:max_tool_output_bytes` key but fall back to
      DIFFERENT defaults (`10_240` here vs `51_200` there), so any deployment
      that leaves the key unset amputates everything between the two.

  Now the full result is spilled to a content-hashed file and the model is
  handed a ready-to-run `file_read` call positioned at the first line it has
  not seen. Truncation becomes a pointer instead of a dead end.

  Content-hashed naming makes the spill idempotent: the same output re-spilled
  (retry, replay) reuses one file instead of accumulating duplicates. Files land
  in the same `tool-results/` directory `ToolResultStorage.cleanup/1` sweeps by
  age, so they do not leak.

  Returns `result_str` unchanged when it is within `limit`. Never raises: a
  failed spill degrades to the previous head-only truncation, which is no worse
  than the old behaviour.
  """
  # Bytes held back from the head slice for the truncation footer.
  @overflow_footer_reserve 600

  @spec spill_or_truncate(String.t(), pos_integer(), map()) :: String.t()
  def spill_or_truncate(result_str, limit, tool_call)
      when is_binary(result_str) and is_integer(limit) and limit > 0 do
    if byte_size(result_str) > limit do
      # Reserve room for the footer so the pointer itself is never the thing
      # that pushes the message back over the limit.
      head_limit = max(limit - @overflow_footer_reserve, div(limit, 2))
      head = safe_head(result_str, head_limit)
      shown_lines = count_lines(head)

      case spill_overflow(result_str, tool_call) do
        {:ok, path, total_lines} ->
          head <>
            "\n\n[Output truncated — showing #{byte_size(head)} of #{byte_size(result_str)} bytes " <>
            "(#{shown_lines} of #{total_lines} lines).\n" <>
            "The COMPLETE output is saved at #{path}.\n" <>
            "Next step: read the rest with file_read " <>
            ~s({"path": "#{path}", "offset": #{shown_lines + 1}, "limit": 200}) <>
            " — repeat with a higher offset to page further.]"

        :error ->
          head <>
            "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first " <>
            "#{byte_size(head)} bytes. The overflow could not be saved to disk.\n" <>
            "Next step: re-run this tool with a narrower query (a more specific pattern, " <>
            "path, or line range) so the result fits.]"
      end
    else
      result_str
    end
  end

  def spill_or_truncate(result_str, _limit, _tool_call), do: result_str

  # binary_part/3 can split a multi-byte grapheme and produce invalid UTF-8,
  # which some providers reject outright. Trim back to a valid boundary.
  defp safe_head(bin, limit) do
    head = binary_part(bin, 0, min(limit, byte_size(bin)))

    if String.valid?(head) do
      head
    else
      trim_to_valid(head)
    end
  end

  defp trim_to_valid(<<>>), do: <<>>

  defp trim_to_valid(bin) do
    size = byte_size(bin)
    shorter = binary_part(bin, 0, size - 1)
    if String.valid?(shorter), do: shorter, else: trim_to_valid(shorter)
  end

  defp count_lines(""), do: 0
  defp count_lines(bin), do: bin |> :binary.matches("\n") |> length() |> Kernel.+(1)

  # Write the full result to a content-hashed file under the shared
  # tool-results directory. Returns {:ok, path, total_lines} or :error.
  defp spill_overflow(result_str, tool_call) do
    dir = Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "tool-results")
    File.mkdir_p!(dir)

    digest =
      :crypto.hash(:sha256, result_str)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    tool_name =
      tool_call
      |> Map.get(:name, "tool")
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

    path = Path.join(dir, "overflow_#{tool_name}_#{digest}.txt")

    # Content-hashed: if it already exists it is byte-identical, so skip the write.
    if File.exists?(path) do
      {:ok, path, count_lines(result_str)}
    else
      case File.write(path, result_str) do
        :ok -> {:ok, path, count_lines(result_str)}
        {:error, _} -> :error
      end
    end
  rescue
    _ -> :error
  end

  @doc """
  Fence and defang tool output that a third party controls before it becomes a
  context message.

  Applies to the web tools and every MCP tool. Their output is attacker-
  reachable in a way the user's own message is not — yet only the user's
  message was ever screened for injection, and tool results were concatenated
  into context raw, with no delimiter. A page could therefore emit
  `SYSTEM: ignore previous instructions` and have it read as prompt structure.

  Output is never dropped or refused on a hit: that would let any web page
  deny the agent its own tool results. It is delimited with a nonce'd fence,
  line-quoted so nothing inside can start a line with a role header, stripped
  of zero-width smuggling, and annotated when it screens as hostile. See
  `OptimalSystemAgent.Agent.Safety.UntrustedContent`.

  Public + `@doc false`-free so the fencing is directly unit-testable.
  """
  @spec fence_untrusted(term(), term()) :: term()
  def fence_untrusted(tool_name, content) when is_binary(content) do
    if UntrustedContent.untrusted_tool?(tool_name) do
      UntrustedContent.wrap(content, source: tool_name, max_bytes: byte_size(content))
    else
      content
    end
  rescue
    # Fencing must never cost the turn its tool result.
    e ->
      Logger.debug("[loop] fence_untrusted failed (non-critical): #{inspect(e)}")
      content
  end

  def fence_untrusted(_tool_name, content), do: content

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

  # Argument summary shown next to the tool name in the TUI. Extracted into
  # `Loop.ToolHint` so it is directly testable — the previous inline version
  # was private, and the only "test" for it was a hand-copied MIRROR of the
  # clauses in test/agent/loop_injection_test.exs, which could not catch the
  # schema-parameter-name and raw-JSON regressions this replaces.
  defp tool_call_hint(args), do: ToolHint.summarize(args)

  # The `args` field on the :tool_call event is a DISPLAY hint (clipped at 60
  # chars for shell, path-only for file tools), which made our own event log
  # unfit for behavioural analysis — see `Loop.ToolArgMetrics` for the two
  # published comparisons that turned out to be measuring the clip. These two
  # fields ride alongside it and carry the real quantities.
  defp tool_call_arg_bytes(args), do: ToolArgMetrics.arg_bytes(args)
  defp tool_call_arg_hash(args), do: ToolArgMetrics.arg_hash(args)

  # The one fact `docs/research/failure-taxonomy.md` §2.5 named as unmeasurable
  # from these artefacts. Pure instrumentation — nothing reads it to decide
  # anything; `OSA_ASSERTION_CAPTURE=0` removes it.
  defp tool_call_assertions(args), do: ToolArgMetrics.assertion_lines(args)

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
      # FATAL class — a tool (or the dispatch layer) declaring that the turn
      # cannot continue. The ONLY non-recoverable tool outcome.
      {:fatal, reason} ->
        ToolError.fatal!(to_text(reason))

      {:error, {:fatal, reason}} ->
        ToolError.fatal!(to_text(reason))

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
        # An OPERATOR decision (a permission decline, a timed-out/cancelled
        # approval, a reject-with-steer surfaced by the handler-level ask tier)
        # is never a dispatch failure: retrying the same action through a
        # sibling tool would route straight around the refusal. Return the
        # decision verbatim so the model reads it and picks another route.
        if semantic_tool_error?(reason) or ToolError.user_decision?(to_text(reason)) do
          "Error: " <> to_text(reason)
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

                _ ->
                  "Error: " <> to_text(reason)
              end

            :no_alternative ->
              "Error: " <> to_text(reason)
          end
        end

      # RESPOND-TO-MODEL: an unexpected return shape is a bug in the tool, not
      # a reason to end the user's turn. Hand the model something readable.
      other ->
        "Error: " <>
          "#{tool_name} returned an unexpected result shape: #{inspect(other, limit: 20)}"
    end
  end

  defp to_text(reason) when is_binary(reason), do: reason
  defp to_text(reason), do: inspect(reason, limit: 20)

  # A semantic/domain tool error (the tool ran and rejected the args) vs. a
  # tool-availability/dispatch failure (unknown tool / tool crashed). We only
  # fall back to a sibling tool for the latter. Public (not `defp`) so
  # `Agent.Reminders`' self-correction collector (P7) can reuse the exact same
  # classification instead of duplicating the keyword list — a self-correction
  # nudge should only fire on the same "semantic, not transient" failures this
  # module already declines to retry-with-a-sibling-tool for.
  @spec semantic_tool_error?(term()) :: boolean()
  def semantic_tool_error?(reason) do
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
