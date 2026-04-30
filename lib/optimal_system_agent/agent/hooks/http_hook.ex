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
    hooks_config = OptimalSystemAgent.Settings.get(:hooks) || %{}

    Enum.each(hooks_config, fn {event_name, hook_list} ->
      event = String.to_existing_atom(event_name)

      if is_list(hook_list) do
        Enum.each(hook_list, fn
          %{"type" => "http", "url" => url} = hook_config ->
            headers = Map.get(hook_config, "headers", %{})
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
  rescue
    _ -> :ok
  end
end
