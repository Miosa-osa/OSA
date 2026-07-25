defmodule OptimalSystemAgent.Agent.Scheduler.JobExecutor do
  @moduledoc """
  Executes cron jobs, trigger actions, and agent tasks.

  Handles the four cron job types (agent, command, webhook, unknown), the three
  trigger action types (agent, command, unknown), shell command execution with
  security validation and output limits, outbound HTTP for webhook jobs, and
  template interpolation for trigger payloads.
  """
  require Logger

  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Tools.Registry

  @max_output_bytes 102_400
  @webhook_timeout_ms 10_000

  # ── Cron Job Execution ────────────────────────────────────────────────

  def execute_cron_job(%{"type" => "agent", "job" => task} = job) do
    Logger.debug("Cron '#{job["id"]}': running agent task")
    execute_task(task, "cron_#{job["id"]}")
  end

  def execute_cron_job(%{"type" => "command", "command" => command} = job) do
    Logger.debug("Cron '#{job["id"]}': running command")
    run_shell_command(command)
  end

  def execute_cron_job(%{"type" => "webhook"} = job) do
    url = job["url"] || ""
    method = String.upcase(job["method"] || "GET")
    headers = job["headers"] || %{}

    Logger.debug("Cron '#{job["id"]}': sending #{method} #{url}")

    with :ok <- validate_url(url) do
      case http_request(method, url, headers, "") do
        {:ok, _status, _body} ->
          {:ok, "webhook delivered"}

        {:error, reason} ->
          # on_failure: "agent" falls back to an agent task
          if job["on_failure"] == "agent" && is_binary(job["failure_job"]) do
            Logger.info("Cron '#{job["id"]}': webhook failed, running failure_job via agent")
            execute_task(job["failure_job"], "cron_#{job["id"]}_fallback")
          else
            {:error, reason}
          end
      end
    else
      {:error, reason} ->
        Logger.warning("Cron '#{job["id"]}': blocked webhook to #{url} — #{reason}")
        {:error, reason}
    end
  end

  def execute_cron_job(job) do
    {:error, "Unknown job type: #{inspect(job["type"])}"}
  end

  # ── Trigger Action Execution ──────────────────────────────────────────

  def execute_trigger_action(%{"type" => "agent", "job" => job_template} = trigger, payload) do
    task = interpolate(job_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running agent task")
    execute_task(task, "trigger_#{trigger["id"]}")
  end

  def execute_trigger_action(
        %{"type" => "command", "command" => cmd_template} = trigger,
        payload
      ) do
    command = interpolate(cmd_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running command")
    run_shell_command(command)
  end

  def execute_trigger_action(trigger, _payload) do
    {:error, "Unknown trigger type: #{inspect(trigger["type"])}"}
  end

  # ── Template Interpolation ────────────────────────────────────────────

  @doc """
  Replace {{payload}} with the full payload as JSON, {{timestamp}} with the
  current ISO 8601 timestamp, and {{payload.key}} with a specific top-level key
  value. All substituted values are shell-escaped to prevent injection.
  """
  def interpolate(template, payload) when is_binary(template) and is_map(payload) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    payload_json = Jason.encode!(payload)

    template
    |> String.replace("{{timestamp}}", timestamp)
    |> String.replace("{{payload}}", shell_escape(payload_json))
    |> then(fn t ->
      Regex.replace(~r/\{\{payload\.(\w+)\}\}/, t, fn _match, key ->
        value = Map.get(payload, key)
        if is_nil(value), do: "''", else: shell_escape(to_string(value))
      end)
    end)
  end

  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  def shell_escape(value), do: shell_escape(to_string(value))

  # ── Shell Command Execution ───────────────────────────────────────────

  def run_shell_command(command) when is_binary(command) do
    # Scheduled commands must enter the same registry as interactive, MCP,
    # HTTP, and sub-agent calls. The registry is the shared enforcement seam
    # for hard safety, schema validation, central authority, and tool dispatch.
    case Registry.execute("shell_execute", %{
           "command" => command,
           "__session_id__" => "scheduler",
           "__surface__" => "schedule"
         }) do
      {:ok, output} -> {:ok, truncate_shell_output(output)}
      {:ok, output, _metadata} -> {:ok, truncate_shell_output(output)}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected shell execution result: #{inspect(other)}"}
    end
  end

  defp truncate_shell_output(output) when is_binary(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
    else
      output
    end
  end

  defp truncate_shell_output(output), do: to_string(output)

  # ── Outbound HTTP (webhook type) ──────────────────────────────────────

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_scheme}
      is_nil(uri.host) -> {:error, :no_host}
      uri.host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"] -> {:error, :loopback}
      String.starts_with?(uri.host || "", "169.254.") -> {:error, :link_local}
      String.starts_with?(uri.host || "", "10.") -> {:error, :private}
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, uri.host || "") -> {:error, :private}
      String.starts_with?(uri.host || "", "192.168.") -> {:error, :private}
      true -> :ok
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  def http_request(method, url, headers, body) do
    headers_map = Map.new(headers)

    req_opts = [
      headers: headers_map,
      receive_timeout: @webhook_timeout_ms,
      connect_options: [timeout: 5_000]
    ]

    result =
      case String.downcase(method) do
        "get" -> Req.get(url, req_opts)
        "post" -> Req.post(url, [{:body, body} | req_opts])
        "put" -> Req.put(url, [{:body, body} | req_opts])
        "delete" -> Req.delete(url, req_opts)
        "patch" -> Req.patch(url, [{:body, body} | req_opts])
        _ -> Req.get(url, req_opts)
      end

    case result do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "HTTP error: #{Exception.message(e)}"}
  end

  # ── Agent Task Execution ──────────────────────────────────────────────

  @doc """
  Start or reuse a one-shot agent loop, run a task through it, then stop the
  loop process. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def execute_task(task_description, session_id) do
    case SessionManager.ensure_loop(session_id, user_id: "scheduler", channel: :scheduler) do
      :ok ->
        result = SessionManager.process_message(session_id, task_description)
        SessionManager.stop_session(session_id)

        case result do
          {:ok, response} -> {:ok, response}
          {:filtered, _signal} -> {:ok, "filtered"}
          {:error, reason} -> {:error, to_string(reason)}
          other -> {:ok, inspect(other)}
        end

      {:error, reason} ->
        {:error, "Failed to start agent loop: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
