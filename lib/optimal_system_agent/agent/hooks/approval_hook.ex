defmodule OptimalSystemAgent.Agent.Hooks.ApprovalHook do
  @moduledoc """
  The approval hook: one external command that decides every tool call.

  Configured by environment, so a supervisor that launches OSA (MIOSA's agent
  runner, CI, a script) can gate it without writing any settings file:

      OSA_PRE_TOOL_HOOK="/bin/sh /opt/miosa/run-gates/<run>.sh"
      OSA_PRE_TOOL_HOOK_TIMEOUT=86400     # seconds, default 86400
      OSA_PRE_TOOL_HOOK_MATCHER="shell_execute|mcp__.*"   # default: every tool

  ## Protocol (Claude Code `PreToolUse`, so one script serves both)

  Before a tool runs, the command gets the call as one JSON object on stdin:

      {"hook_event_name": "PreToolUse", "session_id": "...", "transcript_path": "",
       "cwd": "/workspace", "permission_mode": "default" | "bypassPermissions" | ...,
       "tool_name": "shell_execute", "tool_input": {"command": "git push"},
       "tool_use_id": "call_..."}

  and answers with its exit code and stdout:

    * exit 0, empty or non-JSON stdout: **allow**.
    * exit 0 with Claude Code JSON: `hookSpecificOutput.permissionDecision`
      `"allow"` allows, `"deny"` denies with `permissionDecisionReason`, `"ask"`
      denies (nobody can answer a prompt in a headless run); `continue: false`
      denies with `stopReason`; legacy `decision: "block"` denies with `reason`.
      `updatedInput` rewrites the tool arguments.
    * exit 2: **deny**. The reason is stdout (its JSON reason fields when it is
      JSON), else stderr.
    * any other exit code, a crash, or no answer within the timeout: **deny**.
      An approval gate that cannot be consulted fails closed.

  A denial becomes the tool's result (`"Blocked: <reason>"`), which the model
  reads and the stream reports as a `tool_result` with `is_error: true`.

  ## Where it sits

  The hook runs in the `pre_tool_use` stage for every covered call, in every
  permission mode, overdrive included: overdrive removes OSA's own prompts, not
  an operator's policy. On an unattended session (a headless `osa run`), an
  ordinary approval that would otherwise be refused is handed to this hook
  instead (`ToolExecutor`), so the hook is what decides it. OSA's hard limits
  still apply first and are not delegable: the circuit breaker, saved deny
  rules, protected paths and unresolvable deletes.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Hooks.{Dispatch, Matcher, ShellHook}

  @env_command "OSA_PRE_TOOL_HOOK"
  @env_timeout "OSA_PRE_TOOL_HOOK_TIMEOUT"
  @env_matcher "OSA_PRE_TOOL_HOOK_MATCHER"
  @default_timeout_s 86_400
  @hook_name "approval_hook"
  # Ahead of the settings-driven command hooks (100) so the gate's verdict is
  # the first external opinion, after OSA's own security checks.
  @priority 90
  @active_key {__MODULE__, :active}

  @type config :: %{command: String.t(), timeout_ms: pos_integer(), matcher: String.t() | nil}

  @doc "The configuration from the environment, or nil when no hook is set."
  @spec config(%{optional(String.t()) => String.t()} | nil) :: config() | nil
  def config(env \\ nil) do
    get = fn key -> if env, do: Map.get(env, key), else: System.get_env(key) end

    case get.(@env_command) do
      command when is_binary(command) ->
        case String.trim(command) do
          "" ->
            nil

          trimmed ->
            %{
              command: trimmed,
              timeout_ms: timeout_ms(get.(@env_timeout)),
              matcher: blank_to_nil(get.(@env_matcher))
            }
        end

      _ ->
        nil
    end
  end

  @doc """
  Register the hook when `OSA_PRE_TOOL_HOOK` is set. Synchronous: the hook is
  in the dispatch table when this returns. Idempotent.
  """
  @spec register_from_env() :: :ok | :not_configured
  def register_from_env do
    case config() do
      nil -> :not_configured
      config -> register(config)
    end
  end

  @doc "Register a hook from an explicit configuration (see `config/1`)."
  @spec register(config()) :: :ok
  def register(%{command: command} = config) do
    Dispatch.insert(:pre_tool_use, @hook_name, &handle(config, &1), @priority, [])
    :persistent_term.put(@active_key, config)

    Logger.info(
      "[hooks] approval hook active (#{if config.matcher, do: "tools matching #{config.matcher}", else: "every tool"}): #{command}"
    )

    :ok
  end

  @doc "Remove the hook (tests, or a supervisor that turns it off)."
  @spec unregister() :: :ok
  def unregister do
    Dispatch.remove(:pre_tool_use, @hook_name)
    :persistent_term.erase(@active_key)
    :ok
  end

  @doc "True when an approval hook is registered."
  @spec active?() :: boolean()
  def active?, do: active_config() != nil

  @doc """
  True when a registered approval hook will run for `tool_name`. This is what
  lets an unattended approval be handed to the hook: a tool outside its matcher
  is never seen by it, so that call keeps OSA's own fail-closed answer.
  """
  @spec covers?(String.t()) :: boolean()
  def covers?(tool_name) when is_binary(tool_name) do
    case active_config() do
      nil -> false
      %{matcher: matcher} -> Matcher.matches?(matcher, tool_name)
    end
  end

  def covers?(_), do: false

  @doc false
  # The dispatch handler. Never raises: a hook that crashes in Dispatch is
  # skipped (allowed), which is exactly wrong for an approval gate.
  @spec handle(config(), map()) :: {:ok, map()} | {:block, String.t()}
  def handle(%{command: command, timeout_ms: timeout_ms, matcher: matcher}, payload) do
    if Matcher.matches?(matcher, to_string(Map.get(payload, :tool_name, ""))) do
      ShellHook.run_command_hook(command, :pre_tool_use, payload, timeout_ms,
        fail_closed: true,
        reason_from: :stdout
      )
    else
      {:ok, payload}
    end
  rescue
    e ->
      {:block,
       "The approval hook could not run (#{Exception.message(e)}), so this action did not run."}
  catch
    kind, reason ->
      {:block,
       "The approval hook could not run (#{inspect({kind, reason}, limit: 5)}), so this action " <>
         "did not run."}
  end

  defp active_config, do: :persistent_term.get(@active_key, nil)

  defp timeout_ms(nil), do: @default_timeout_s * 1000

  defp timeout_ms(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n > 0 -> n * 1000
      _ -> @default_timeout_s * 1000
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end
end
