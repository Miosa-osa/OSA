defmodule OptimalSystemAgent.Agent.Hooks.HttpHook do
  @moduledoc """
  HTTP webhook hook — POST event payloads to external URLs.

  Configured via settings:
  ```json
  {
    "hooks": {
      "post_tool_use": [
        {"type": "http", "url": "https://example.com/webhook", "events": ["post_tool_use"]}
      ]
    }
  }
  ```

  Payloads are JSON-encoded and sent as POST with Content-Type: application/json.
  Hooks never block — failures are logged but don't interrupt execution.
  """
  require Logger

  @timeout_ms 5_000

  @doc """
  Execute an HTTP webhook hook — POST the payload to the configured URL.
  """
  def execute(url, payload, opts \\ []) do
    headers = Keyword.get(opts, :headers, %{})
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    body = Jason.encode!(payload)

    all_headers =
      Map.merge(
        %{"content-type" => "application/json", "user-agent" => "OSA-Webhook/1.0"},
        headers
      )

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      try do
        case Req.post(url,
               body: body,
               headers: all_headers,
               receive_timeout: timeout,
               connect_options: [timeout: timeout]
             ) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.debug("[http_hook] POST #{url} → #{status}")

          {:ok, %{status: status, body: resp_body}} ->
            Logger.warning("[http_hook] POST #{url} → #{status}: #{inspect(resp_body)}")

          {:error, reason} ->
            Logger.warning("[http_hook] POST #{url} failed: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.warning("[http_hook] Exception posting to #{url}: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  @doc """
  Register HTTP webhook hooks from settings configuration.

  Reads hook config from Settings and registers handlers for each URL.
  Called at session startup.
  """
  def register_from_settings do
    if OptimalSystemAgent.Settings.get_trusted("disableAllHooks", false) == true do
      Logger.info("[http_hook] disableAllHooks is set — skipping HTTP hooks")
      :ok
    else
      register_http_hooks(OptimalSystemAgent.Settings.get_merged_hooks())
    end
  rescue
    _ -> :ok
  end

  defp register_http_hooks(hooks_config) do
    Enum.each(hooks_config, fn {event_name, hook_list} ->
      event = resolve_event(event_name)

      if not is_nil(event) and is_list(hook_list) do
        Enum.each(hook_list, fn
          %{"type" => "http", "url" => url} = hook_config ->
            # `|| %{}`: a `"headers": null` in the hook config is a present key,
            # so the Map.get/3 default never fires and nil reached Req.
            headers = Map.get(hook_config, "headers") || %{}
            name = "http_hook_#{event}_#{:erlang.phash2(url)}"

            handler = fn payload ->
              execute(url, Map.put(payload, :hook_event, event), headers: headers)
              {:ok, payload}
            end

            OptimalSystemAgent.Agent.Hooks.register(event, name, handler, priority: 100)
            Logger.debug("[http_hook] Registered #{name} → #{url}")

          _ ->
            :ok
        end)
      end
    end)
  end

  # CC PascalCase hook-event names → OSA snake_case event atoms (the atoms the
  # dispatcher actually fires with). Snake_case names pass through only when the
  # atom already exists; unknown names return nil so a single bad key cannot
  # abort registration of the rest.
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

  defp resolve_event(name) when is_binary(name),
    do: Map.get(@cc_events, name) || safe_existing_atom(name)

  defp resolve_event(_), do: nil

  defp safe_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
