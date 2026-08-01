defmodule OptimalSystemAgent.Agent.Hooks.ShellHook do
  @moduledoc """
  Command hook runner — Claude Code hooks protocol.

  ## Settings shape (CC parity)

  ```json
  {
    "hooks": {
      "PreToolUse": [
        {"matcher": "file_write|file_edit",
         "hooks": [{"type": "command", "command": "check.sh", "timeout": 60}]}
      ]
    }
  }
  ```

  The legacy OSA flat shape (`{"type": "shell", "command": "…{{tool_name}}…"}`)
  is still supported and keeps its fire-and-forget template semantics.

  ## Protocol (per `type: "command"` hook run)

    * The FULL JSON event payload is piped to the command's **stdin**:
      `hook_event_name`, `session_id`, `transcript_path`, `cwd`,
      `permission_mode` plus event-specific fields (`tool_name`, `tool_input`,
      `tool_response`, `prompt`, `stop_hook_active`, `trigger`,
      `custom_instructions`, `source`, …).
    * **exit 0** — stdout is parsed. A JSON object may carry `continue` /
      `stopReason` / `decision` (`approve|block`) / `reason` / `systemMessage` /
      `hookSpecificOutput` (`permissionDecision`, `permissionDecisionReason`,
      `updatedInput`, `additionalContext`). Plain stdout becomes injected
      context for UserPromptSubmit / SessionStart.
    * **exit 2** — BLOCKING: stderr is the reason. Blocking-capable events
      (PreToolUse, UserPromptSubmit, Stop, SubagentStop, PermissionRequest)
      deny the action; post events feed stderr back to the model as context.
    * **any other exit code** — non-blocking error, logged only.
    * Per-hook timeout: `"timeout"` (seconds) in the hook config; default 600s
      (CC `TOOL_HOOK_EXECUTION_TIMEOUT_MS`). Timeout is non-blocking.

  Results are translated into the `Dispatch` handler protocol: `{:block,
  reason}` denies, `{:ok, payload}` continues — with `:arguments` rewritten by
  `updatedInput`, `:injected_context` accumulated from additionalContext /
  stdout, and `:permission_decision` set by `permissionDecision`.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Hooks.Matcher
  alias OptimalSystemAgent.Events.Bus

  # CC default: 10 minutes per hook.
  @default_timeout_ms 600_000
  @legacy_timeout_ms 10_000

  # Events where a block DENIES the action. Elsewhere exit 2 becomes feedback.
  @blocking_events [
    :pre_tool_use,
    :user_prompt_submit,
    :stop,
    :subagent_stop,
    :pre_response,
    :permission_request
  ]

  @cc_events %{
    "PreToolUse" => :pre_tool_use,
    "PostToolUse" => :post_tool_use,
    "PostToolUseFailure" => :post_tool_use_failure,
    "UserPromptSubmit" => :user_prompt_submit,
    "Stop" => :stop,
    "SubagentStart" => :subagent_start,
    "SubagentStop" => :subagent_stop,
    "SessionStart" => :session_start,
    "SessionEnd" => :session_end,
    "PreCompact" => :pre_compact,
    "PostCompact" => :post_compact,
    "Notification" => :notification,
    "PermissionRequest" => :permission_request,
    "PermissionDenied" => :permission_denied
  }

  @cc_names Map.new(@cc_events, fn {cc, atom} -> {atom, cc} end)

  # ── Settings loading ─────────────────────────────────────────────────

  @doc "Register hooks from settings (both CC and legacy shapes)."
  def register_from_settings do
    if OptimalSystemAgent.Settings.get_trusted("disableAllHooks", false) == true do
      Logger.info("[hooks] disableAllHooks is set — skipping settings-driven hooks")
      :ok
    else
      OptimalSystemAgent.Settings.get_merged_hooks()
      |> hook_specs()
      |> Enum.each(&register_spec/1)
    end
  rescue
    _ -> :ok
  end

  @doc """
  Pure parse of a merged `\"hooks\"` settings map into runnable specs.

  Understands the CC shape (`{matcher, hooks: [{type: \"command\", …}]}` under
  PascalCase event names) and the legacy flat shape (`{type: \"shell\",
  command}` under snake_case event names).
  """
  def hook_specs(hooks_config) when is_map(hooks_config) do
    Enum.flat_map(hooks_config, fn {event_name, entries} ->
      case resolve_event(event_name) do
        nil -> []
        event -> Enum.flat_map(List.wrap(entries), &entry_specs(event, &1))
      end
    end)
  end

  def hook_specs(_), do: []

  defp entry_specs(event, %{"hooks" => hooks} = entry) when is_list(hooks) do
    matcher = Map.get(entry, "matcher")
    Enum.flat_map(hooks, &command_spec(event, matcher, &1))
  end

  defp entry_specs(event, %{"type" => "shell", "command" => cmd}) when is_binary(cmd) do
    [%{event: event, matcher: nil, command: cmd, timeout_ms: @default_timeout_ms, mode: :legacy}]
  end

  defp entry_specs(event, %{"type" => "command", "command" => _} = hook),
    do: command_spec(event, nil, hook)

  defp entry_specs(_event, _entry), do: []

  # Inside a CC matcher group, "type": "command" is the default.
  defp command_spec(event, matcher, %{"command" => cmd} = hook) when is_binary(cmd) do
    if Map.get(hook, "type", "command") == "command" do
      [%{event: event, matcher: matcher, command: cmd, timeout_ms: parse_timeout(hook), mode: :command}]
    else
      []
    end
  end

  defp command_spec(_event, _matcher, _hook), do: []

  defp parse_timeout(%{"timeout" => s}) when is_number(s) and s > 0, do: round(s * 1000)
  defp parse_timeout(_), do: @default_timeout_ms

  defp resolve_event(name) when is_binary(name) do
    Map.get(@cc_events, name) || legacy_event(name)
  end

  defp resolve_event(_), do: nil

  defp legacy_event(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp register_spec(%{mode: :legacy, event: event, command: command}) do
    name = "shell_hook_#{event}_#{:erlang.phash2(command)}"

    handler = fn payload ->
      execute(command, payload)
      {:ok, payload}
    end

    OptimalSystemAgent.Agent.Hooks.register(event, name, handler, priority: 100)
    Logger.debug("[shell_hook] Registered legacy #{name}")
  end

  defp register_spec(%{mode: :command} = spec) do
    %{event: event, matcher: matcher, command: command, timeout_ms: timeout_ms} = spec
    name = "command_hook_#{event}_#{:erlang.phash2({matcher, command})}"

    handler = fn payload ->
      if Matcher.matches?(matcher, match_query(event, payload)) do
        run_command_hook(command, event, payload, timeout_ms)
      else
        {:ok, payload}
      end
    end

    OptimalSystemAgent.Agent.Hooks.register(event, name, handler, priority: 100)
    Logger.debug("[shell_hook] Registered #{name}")
  end

  # What the matcher is matched against, per event (CC: tool name for tool
  # events, source for SessionStart, trigger for PreCompact; nil = no matcher
  # dimension → matchers ignored).
  defp match_query(event, payload)
       when event in [
              :pre_tool_use,
              :post_tool_use,
              :post_tool_use_failure,
              :permission_request,
              :permission_denied
            ],
       do: to_string(Map.get(payload, :tool_name, ""))

  defp match_query(:session_start, payload), do: to_string(Map.get(payload, :source, "startup"))
  defp match_query(:pre_compact, payload), do: to_string(Map.get(payload, :trigger, "auto"))
  defp match_query(_event, _payload), do: nil

  # ── CC command-hook runner ───────────────────────────────────────────

  @doc """
  Run one CC-protocol command hook synchronously in the caller's process.
  Returns the `Dispatch` handler protocol (`{:ok, payload}` / `{:block, reason}`).
  """
  def run_command_hook(command, event, payload, timeout_ms \\ @default_timeout_ms) do
    input_json = encode_input(event, payload)

    case spawn_hook(command, input_json, payload, timeout_ms) do
      :timeout ->
        Logger.warning("[hooks] Command hook timed out after #{timeout_ms}ms: #{command}")
        {:ok, payload}

      {stdout, stderr, code} ->
        interpret(event, payload, command, stdout, stderr, code)
    end
  end

  @doc """
  Build the CC-shaped hook input written to the hook's stdin.
  Base fields plus per-event fields (tool_name/tool_input/tool_response,
  prompt, stop_hook_active, trigger/custom_instructions, source, message).
  """
  def build_hook_input(event, payload) do
    base = %{
      "hook_event_name" => cc_event_name(event),
      "session_id" => to_string(Map.get(payload, :session_id, "unknown")),
      # OSA transcripts are DB-backed (no per-session jsonl file yet).
      "transcript_path" => "",
      "cwd" => Map.get(payload, :working_dir) || safe_cwd(),
      "permission_mode" => to_string(Map.get(payload, :permission_mode, "default"))
    }

    Map.merge(base, event_fields(event, payload))
  end

  defp cc_event_name(event),
    do: Map.get(@cc_names, event, event |> Atom.to_string() |> Macro.camelize())

  defp event_fields(event, payload)
       when event in [:pre_tool_use, :permission_request, :permission_denied] do
    %{
      "tool_name" => to_string(Map.get(payload, :tool_name, "")),
      "tool_input" => Map.get(payload, :arguments) || %{}
    }
  end

  defp event_fields(event, payload) when event in [:post_tool_use, :post_tool_use_failure] do
    %{
      "tool_name" => to_string(Map.get(payload, :tool_name, "")),
      "tool_input" => Map.get(payload, :arguments) || %{},
      "tool_response" => to_string(Map.get(payload, :result, ""))
    }
  end

  defp event_fields(:user_prompt_submit, payload),
    do: %{"prompt" => to_string(Map.get(payload, :message, ""))}

  defp event_fields(event, payload) when event in [:stop, :subagent_stop],
    do: %{"stop_hook_active" => Map.get(payload, :stop_hook_active, false) == true}

  defp event_fields(:pre_compact, payload) do
    %{
      "trigger" => to_string(Map.get(payload, :trigger, "auto")),
      "custom_instructions" => to_string(Map.get(payload, :custom_instructions, ""))
    }
  end

  defp event_fields(:session_start, payload),
    do: %{"source" => to_string(Map.get(payload, :source, "startup"))}

  defp event_fields(:notification, payload),
    do: %{"message" => to_string(Map.get(payload, :message, ""))}

  defp event_fields(_event, _payload), do: %{}

  defp encode_input(event, payload) do
    case Jason.encode(build_hook_input(event, payload)) do
      {:ok, json} ->
        json

      {:error, _} ->
        # Non-encodable payload field (tuple, pid, …) — fall back to base input.
        Jason.encode!(%{
          "hook_event_name" => cc_event_name(event),
          "session_id" => to_string(Map.get(payload, :session_id, "unknown")),
          "transcript_path" => "",
          "cwd" => safe_cwd()
        })
    end
  end

  # Spawn the hook through the platform shell with the JSON payload on stdin
  # and stderr captured separately (stdout is the JSON/plain protocol channel,
  # stderr is the exit-2 block reason).
  defp spawn_hook(command, input_json, payload, timeout_ms) do
    base = Path.join(System.tmp_dir!(), "osa-hook-#{System.unique_integer([:positive])}")
    in_file = base <> ".in"
    err_file = base <> ".err"

    try do
      File.write!(in_file, input_json <> "\n")

      wrapped = "( #{command}\n) < #{quote_path(in_file)} 2> #{quote_path(err_file)}"

      task =
        Task.async(fn ->
          try do
            OptimalSystemAgent.OS.Shell.cmd(wrapped, env: build_env(payload))
          rescue
            e -> {"Error occurred while executing hook command: #{Exception.message(e)}", 1}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {stdout, code}} ->
          stderr =
            case File.read(err_file) do
              {:ok, s} -> s
              _ -> ""
            end

          {stdout, stderr, code}

        nil ->
          :timeout
      end
    after
      File.rm(in_file)
      File.rm(err_file)
    end
  end

  defp quote_path(path) do
    case :os.type() do
      {:win32, _} -> "\"" <> path <> "\""
      _ -> "'" <> String.replace(path, "'", "'\\''") <> "'"
    end
  end

  defp safe_cwd do
    case File.cwd() do
      {:ok, dir} -> dir
      _ -> System.tmp_dir!()
    end
  end

  # ── Result interpretation (CC exit 0/2/other + JSON stdout schema) ──

  defp interpret(event, payload, command, stdout, stderr, code) do
    trimmed = String.trim(stdout)

    cond do
      code == 2 ->
        reason =
          case String.trim(stderr) do
            "" -> "Blocked by hook: #{command}"
            s -> s
          end

        blocking_result(event, payload, reason)

      code == 0 and String.starts_with?(trimmed, "{") ->
        case Jason.decode(trimmed) do
          {:ok, json} when is_map(json) ->
            apply_json(event, payload, command, json)

          _ ->
            Logger.warning("[hooks] Hook stdout is not valid JSON (treated as text): #{command}")
            plain_stdout(event, payload, trimmed)
        end

      code == 0 ->
        plain_stdout(event, payload, trimmed)

      true ->
        Logger.warning(
          "[hooks] #{command} failed with non-blocking status #{code}: " <>
            String.slice(String.trim(stderr), 0, 300)
        )

        {:ok, payload}
    end
  end

  # Blocking-capable events deny; post events feed the reason back as context.
  defp blocking_result(event, _payload, reason) when event in @blocking_events,
    do: {:block, reason}

  defp blocking_result(_event, payload, reason),
    do: {:ok, add_context(payload, "[hook feedback] " <> reason)}

  # Exit-0 plain stdout becomes injected context for prompt-shaped events (CC).
  defp plain_stdout(event, payload, trimmed)
       when event in [:user_prompt_submit, :session_start] and trimmed != "" do
    {:ok, add_context(payload, trimmed)}
  end

  defp plain_stdout(_event, payload, trimmed) do
    if trimmed != "" do
      Logger.debug("[hooks] hook stdout: #{String.slice(trimmed, 0, 200)}")
    end

    {:ok, payload}
  end

  defp apply_json(event, payload, command, json) do
    payload =
      case Map.get(json, "systemMessage") do
        msg when is_binary(msg) and msg != "" -> add_system_message(payload, msg)
        _ -> payload
      end

    cond do
      # continue:false halts processing — EXCEPT on Stop/SubagentStop where it
      # means "definitely stop" (i.e. allow the stop to proceed).
      Map.get(json, "continue") == false and event not in [:stop, :subagent_stop] ->
        {:block, Map.get(json, "stopReason") || "Hook requested stop (continue: false)"}

      Map.get(json, "decision") == "block" ->
        blocking_result(event, payload, Map.get(json, "reason") || "Blocked by hook: #{command}")

      true ->
        payload =
          if Map.get(json, "decision") == "approve" do
            Map.put(payload, :permission_decision, :allow)
          else
            payload
          end

        apply_hook_specific(event, payload, command, json, Map.get(json, "hookSpecificOutput"))
    end
  end

  defp apply_hook_specific(event, payload, command, json, %{} = hso) do
    payload =
      case Map.get(hso, "additionalContext") do
        ctx when is_binary(ctx) and ctx != "" -> add_context(payload, ctx)
        _ -> payload
      end

    payload =
      case Map.get(hso, "updatedInput") do
        %{} = updated -> Map.put(payload, :arguments, updated)
        _ -> payload
      end

    case Map.get(hso, "permissionDecision") do
      "deny" ->
        reason =
          Map.get(hso, "permissionDecisionReason") || Map.get(json, "reason") ||
            "Blocked by hook: #{command}"

        blocking_result(event, payload, reason)

      "allow" ->
        {:ok, Map.put(payload, :permission_decision, :allow)}

      "ask" ->
        {:ok, Map.put(payload, :permission_decision, :ask)}

      _ ->
        {:ok, payload}
    end
  end

  defp apply_hook_specific(_event, payload, _command, _json, _hso), do: {:ok, payload}

  defp add_context(payload, ctx) do
    Map.update(payload, :injected_context, [ctx], &(&1 ++ [ctx]))
  end

  # systemMessage is a user-facing warning (CC): surface via the event bus and
  # keep it on the payload for call-sites that render it.
  defp add_system_message(payload, msg) do
    try do
      Bus.emit(:system_event, %{
        event: :hook_system_message,
        message: msg,
        session_id: Map.get(payload, :session_id, "unknown")
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    Map.update(payload, :system_messages, [msg], &(&1 ++ [msg]))
  end

  # ── Legacy fire-and-forget template hooks ────────────────────────────

  @doc """
  Legacy fire-and-forget shell hook with `{{key}}` template interpolation.
  Used by legacy `{\"type\": \"shell\"}` settings entries; new hooks should
  use the CC `{\"type\": \"command\"}` protocol via `run_command_hook/4`.
  """
  def execute(command_template, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @legacy_timeout_ms)
    command = interpolate(command_template, payload)

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      try do
        inner =
          Task.async(fn ->
            OptimalSystemAgent.OS.Shell.cmd(command,
              stderr_to_stdout: true,
              env: build_env(payload)
            )
          end)

        case Task.yield(inner, timeout) || Task.shutdown(inner, :brutal_kill) do
          {:ok, {output, 0}} ->
            output = String.trim(output)

            if output != "" do
              Logger.debug("[shell_hook] #{command} → #{String.slice(output, 0, 200)}")
            end

          {:ok, {output, code}} ->
            Logger.warning(
              "[shell_hook] #{command} exited #{code}: #{String.slice(output, 0, 200)}"
            )

          nil ->
            Logger.warning("[shell_hook] Timed out: #{command}")
        end
      rescue
        e -> Logger.warning("[shell_hook] Failed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  # ── Private (shared) ─────────────────────────────────────────────────

  defp interpolate(template, payload) when is_map(payload) do
    # Shell-escape each substituted value so tool/model-influenced payload
    # fields (e.g. {{result}} containing `; rm -rf ~`) become an inert quoted
    # literal instead of executable shell.
    Enum.reduce(payload, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", shell_escape(to_string(value)))
    end)
  end

  defp interpolate(template, _), do: template

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  # Environment variables from scalar payload fields, plus the project dir
  # (CC's CLAUDE_PROJECT_DIR equivalent).
  defp build_env(payload) when is_map(payload) do
    vars =
      payload
      |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_atom(v) end)
      |> Enum.map(fn {k, v} -> {"OSA_#{String.upcase(to_string(k))}", to_string(v)} end)

    [{"OSA_PROJECT_DIR", safe_cwd()} | vars]
  end

  defp build_env(_), do: [{"OSA_PROJECT_DIR", safe_cwd()}]
end
