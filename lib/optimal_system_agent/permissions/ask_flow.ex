defmodule OptimalSystemAgent.Permissions.AskFlow do
  @moduledoc """
  The `:ask` tier for tool-handler permission checks.

  A structured tool's `check_permissions/2` may return `{:ask, reason}` — the
  MIDDLE safety tier (`curl | sh`, `git push --force`, a write under `/etc`,
  a file mutation that escapes the workspace). Before this module existed
  `Tools.LegacyAdapter` turned every one of those into the hard error
  `"Permission ask flow not yet wired"`, so the tier did not exist: a command
  was either allowed or it failed with an internal message that the model then
  tried to route around via `suggest_fallback_tool/1`.

  This wires that branch to the SAME interactive mechanism the agent loop's
  `ToolExecutor` uses — `Agent.Loop.PermissionBroker` — rather than inventing a
  second flow:

    1. emit a `permission_required` system event (session PubSub + Bus), the
       payload the TUI permission dialog already consumes;
    2. park the calling process on `PermissionBroker.await/3`;
    3. map the decision onto `:allow` or a NON-FATAL, model-readable
       `{:error, reason}` whose wording `Agent.Loop.ToolError.user_decision?/1`
       recognises, so repeated declines can never trip the doom-loop
       failure-signature halt.

  ## Double-prompt avoidance

  Calls that arrive through the agent loop have ALREADY been approved by
  `ToolExecutor.approve_tool_call/2` (interactively, by a saved rule, or by the
  permission mode). `ToolExecutor` records that with `mark_call_approved/2`
  keyed on the tool_use id, and `request/4` short-circuits on it — the operator
  answers one dialog, not two. Callers that never went through the loop (the
  MCP server dispatcher, `Tools.Pipeline`, HTTP tool routes, the cron
  scheduler, sub-agent tasks) carry no mark and get the real prompt.

  ## Non-interactive channels

  Fail closed, matching `ToolExecutor.non_interactive_decision/1`: without a
  session to prompt, or on a session `Agent.Attendance` reports nobody is
  attached to, the call is refused with an honest, actionable message — unless
  the explicit `:non_interactive_permission_bypass` opt-out is set
  (config/test.exs and deliberate unattended runs). Attendance is the ONE
  answer to "can a human respond right now"; this module used to carry its own
  private copy of an app-env read, one of three that had drifted apart.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Attendance
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Tools.UseContext

  @approved_calls :osa_permission_call_approved

  @doc """
  Record that `tool_use_id` was already approved for `session_id`, so a
  handler-level `{:ask, _}` for the same call does not prompt a second time.
  """
  @spec mark_call_approved(String.t() | nil, String.t() | nil) :: :ok
  def mark_call_approved(session_id, tool_use_id)
      when is_binary(session_id) and is_binary(tool_use_id) do
    ensure_table()
    :ets.insert(@approved_calls, {{session_id, tool_use_id}, true})
    :ok
  rescue
    _ -> :ok
  end

  def mark_call_approved(_, _), do: :ok

  @doc "Whether `tool_use_id` was already approved this session."
  @spec call_approved?(String.t() | nil, String.t() | nil) :: boolean()
  def call_approved?(session_id, tool_use_id)
      when is_binary(session_id) and is_binary(tool_use_id) do
    ensure_table()

    case :ets.lookup(@approved_calls, {session_id, tool_use_id}) do
      [{_, true}] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def call_approved?(_, _), do: false

  @doc """
  Run the interactive ask flow for `tool_name`.

  Returns `:allow` when the call may proceed, or `{:error, reason}` — a
  non-fatal, model-readable refusal. Never raises and never returns a fatal
  shape: an operator declining is a normal turn event, not a malfunction.
  """
  @spec request(String.t(), map(), UseContext.t() | nil, String.t() | nil) ::
          :allow | {:error, String.t()}
  def request(tool_name, input, ctx, reason) when is_binary(tool_name) do
    session_id = session_id_of(ctx, input)
    tool_use_id = tool_use_id_of(ctx, input)

    cond do
      call_approved?(session_id, tool_use_id) ->
        :allow

      PermissionBroker.session_allowed?(session_id, tool_name) ->
        :allow

      not is_binary(session_id) or not Attendance.attended?(session_id) ->
        non_interactive_decision(tool_name, reason, session_id)

      true ->
        prompt(tool_name, input, session_id, reason)
    end
  rescue
    e ->
      # A broken prompt path must fail CLOSED, and must still be a normal
      # model-readable result rather than a crash that ends the turn.
      Logger.error("[permissions] ask flow error for #{tool_name}: #{Exception.message(e)}")
      {:error, refusal(tool_name, "the approval prompt could not be shown")}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp prompt(tool_name, input, session_id, reason) do
    request_id = PermissionBroker.new_request_id()
    emit_permission_required(session_id, request_id, tool_name, input, reason)

    case PermissionBroker.await(session_id, request_id) do
      {:ok, %{decision: decision, note: note}} ->
        apply_decision(decision, note, tool_name, input, session_id)

      # Attendance ended between the decision to prompt and the wait itself.
      # Same answer the earlier branch would have given — never a park.
      {:error, :unattended} ->
        non_interactive_decision(tool_name, reason, session_id)

      {:error, :timeout} ->
        {:error,
         "Blocked: permission request for #{tool_name} timed out with no response — not run"}

      {:error, :cancelled} ->
        {:error, "Blocked: #{tool_name} cancelled before approval"}
    end
  end

  # Mirrors `ToolExecutor.apply_permission_decision/4`, mapped onto the
  # `{:allow, _} | {:error, _}` shape the tool-handler pipeline speaks.
  defp apply_decision(decision, note, tool_name, input, session_id) do
    case decision do
      :allow_once ->
        :allow

      :allow_session ->
        PermissionBroker.allow_for_session(session_id, tool_name)
        :allow

      :allow_always ->
        # `suggested_rule/2` returns nil when no honest "always" rule exists
        # (an interpreter/shell prefix, a heredoc, a compound command); the
        # call is still allowed ONCE, nothing over-broad is persisted.
        case Permissions.suggested_rule(tool_name, strip_internal(input)) do
          nil -> :ok
          rule -> Permissions.save_rule(rule, :allow_always)
        end

        :allow

      :deny ->
        {:error, "Blocked: you declined to run #{tool_name}"}

      :deny_always ->
        case Permissions.suggested_rule(tool_name, strip_internal(input)) do
          nil -> Permissions.save_rule(tool_name, :deny_always)
          rule -> Permissions.save_rule(rule, :deny_always)
        end

        {:error, "Blocked: #{tool_name} denied and saved as a standing rule"}

      :clarify ->
        case String.trim(note || "") do
          "" -> {:error, "Blocked: you asked to reconsider #{tool_name}"}
          steer -> {:error, "Blocked: you asked to reconsider #{tool_name} — #{steer}"}
        end
    end
  end

  # OBSERVABLE, in both directions. The auto-ALLOW under the explicit bypass is
  # a permission decision taken with no human in it and used to be silent.
  defp non_interactive_decision(tool_name, reason, session_id) do
    why = Attendance.reason(session_id)

    if Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false) do
      Logger.warning(
        "[permissions] auto-ALLOWED #{tool_name} without asking — unattended session " <>
          "(#{why}) and :non_interactive_permission_bypass is set"
      )

      emit_non_interactive(:allow, tool_name, session_id, why)
      :allow
    else
      Logger.info(
        "[permissions] auto-DENIED #{tool_name} — unattended session (#{why}), " <>
          "permissions fail closed"
      )

      emit_non_interactive(:deny, tool_name, session_id, why)
      {:error, refusal(tool_name, reason)}
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

  # Contains "requires interactive approval" so `ToolError.user_decision?/1`
  # classifies it as an operator decision, not a tool malfunction.
  defp refusal(tool_name, reason) do
    detail = if is_binary(reason) and reason != "", do: " (#{reason})", else: ""

    "Blocked: #{tool_name} requires interactive approval#{detail}, but this channel " <>
      "cannot prompt — auto-rejected (permissions fail closed). Approve it from an " <>
      "interactive session, or save an allow rule for this exact command."
  end

  defp emit_permission_required(session_id, request_id, tool_name, input, reason) do
    args = strip_internal(input)

    payload = %{
      type: :system_event,
      event: :permission_required,
      session_id: session_id,
      request_id: request_id,
      tool: tool_name,
      args: arg_hint(args),
      target: arg_hint(args),
      kind: kind_of(tool_name),
      old_content: nil,
      new_content: nil,
      warning: nil,
      reason: reason,
      suggestions: suggestions(tool_name, args)
    }

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, payload}
    )

    Bus.emit(:system_event, Map.delete(payload, :type), source: "permissions.ask_flow")
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp suggestions(tool_name, args) do
    case Permissions.suggested_rule(tool_name, args) do
      nil ->
        []

      rule ->
        [%{type: "addRules", behavior: "allow", rule: rule, destination: "localSettings"}]
    end
  rescue
    _ -> []
  end

  @hint_limit 120
  defp arg_hint(args) when is_map(args) do
    value =
      args["command"] || args["code"] || args["path"] || args["file_path"] || args["url"] ||
        args["target"]

    case value do
      v when is_binary(v) ->
        case v |> String.trim() |> String.replace(~r/\s+/, " ") do
          "" -> ""
          s when byte_size(s) > @hint_limit -> binary_part(s, 0, @hint_limit) <> "…"
          s -> s
        end

      _ ->
        ""
    end
  end

  defp arg_hint(_), do: ""

  defp kind_of(name) do
    cond do
      name in OptimalSystemAgent.Agent.Safety.DangerousCommands.shell_tools() -> "bash"
      name in ["file_edit", "multi_file_edit"] -> "file_edit"
      name in ["file_write", "file_create"] -> "file_write"
      name in ["file_delete", "file_move"] -> "file_delete"
      name in ["web_fetch", "web_search", "download"] -> "fetch"
      String.starts_with?(name, "mcp__") -> "mcp"
      true -> "other"
    end
  end

  # The loop injects `__session_id__` / `__tool_use_id__` / `__surface__` into
  # every call; they are plumbing, not permission-relevant arguments.
  defp strip_internal(input) when is_map(input) do
    Map.drop(input, [
      "__session_id__",
      "__tool_use_id__",
      "__surface__",
      :__session_id__,
      :__tool_use_id__,
      :__surface__
    ])
  end

  defp strip_internal(_), do: %{}

  defp session_id_of(%UseContext{session_id: sid}, _input) when is_binary(sid) and sid != "",
    do: sid

  defp session_id_of(_ctx, input) when is_map(input),
    do: binary_or_nil(input["__session_id__"] || input[:__session_id__])

  defp session_id_of(_, _), do: nil

  defp tool_use_id_of(%UseContext{tool_use_id: id}, _input) when is_binary(id) and id != "",
    do: id

  defp tool_use_id_of(_ctx, input) when is_map(input),
    do: binary_or_nil(input["__tool_use_id__"] || input[:__tool_use_id__])

  defp tool_use_id_of(_, _), do: nil

  defp binary_or_nil(v) when is_binary(v) and v != "", do: v
  defp binary_or_nil(_), do: nil

  defp ensure_table do
    case :ets.whereis(@approved_calls) do
      :undefined ->
        :ets.new(@approved_calls, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
