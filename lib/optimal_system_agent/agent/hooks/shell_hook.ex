defmodule OptimalSystemAgent.Agent.Hooks.ShellHook do
  @moduledoc """
  Shell command hook — run bash commands on hook events.

  Configured via settings:
  ```json
  {
    "hooks": {
      "post_tool_use": [
        {"type": "shell", "command": "echo 'Tool used: {{tool_name}}' >> /tmp/osa.log"}
      ]
    }
  }
  ```

  Template variables in the command are interpolated from the event payload:
  {{tool_name}}, {{session_id}}, {{result}}, {{duration_ms}}, etc.

  Hooks are fire-and-forget — they never block agent execution.
  Non-zero exit code is logged but doesn't affect the agent.
  """
  require Logger

  @timeout_ms 10_000

  @doc "Execute a shell command hook with payload interpolation."
  def execute(command_template, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout_ms)
    command = interpolate(command_template, payload)

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      try do
        case System.cmd("sh", ["-c", command],
          stderr_to_stdout: true,
          env: build_env(payload),
          timeout: timeout
        ) do
          {output, 0} ->
            output = String.trim(output)
            if output != "" do
              Logger.debug("[shell_hook] #{command} → #{String.slice(output, 0, 200)}")
            end

          {output, code} ->
            Logger.warning("[shell_hook] #{command} exited #{code}: #{String.slice(output, 0, 200)}")
        end
      rescue
        e -> Logger.warning("[shell_hook] Failed: #{Exception.message(e)}")
      catch
        :exit, {:timeout, _} -> Logger.warning("[shell_hook] Timed out: #{command}")
      end
    end)

    :ok
  end

  @doc "Register shell hooks from settings configuration."
  def register_from_settings do
    hooks_config = OptimalSystemAgent.Settings.get(:hooks) || %{}

    Enum.each(hooks_config, fn {event_name, hook_list} ->
      event = String.to_existing_atom(event_name)

      if is_list(hook_list) do
        Enum.each(hook_list, fn
          %{"type" => "shell", "command" => command} ->
            name = "shell_hook_#{event}_#{:erlang.phash2(command)}"

            handler = fn payload ->
              execute(command, payload)
              {:ok, payload}
            end

            OptimalSystemAgent.Agent.Hooks.register(event, name, handler, priority: 100)
            Logger.debug("[shell_hook] Registered #{name}")

          _ ->
            :ok
        end)
      end
    end)
  rescue
    _ -> :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp interpolate(template, payload) when is_map(payload) do
    Enum.reduce(payload, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp interpolate(template, _), do: template

  # Build environment variables from payload for the shell command
  defp build_env(payload) when is_map(payload) do
    payload
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_atom(v) end)
    |> Enum.map(fn {k, v} -> {"OSA_#{String.upcase(to_string(k))}", to_string(v)} end)
  end

  defp build_env(_), do: []
end
