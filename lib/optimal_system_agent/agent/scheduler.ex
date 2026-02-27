defmodule OptimalSystemAgent.Agent.Scheduler do
  @moduledoc """
  Periodic task scheduler with HEARTBEAT.md, CRONS.json, and TRIGGERS.json support.

  ## HEARTBEAT.md

  Checks `~/.osa/HEARTBEAT.md` every 30 minutes. If the file contains
  tasks (markdown checklist items), the agent executes them through the
  standard Agent.Loop pipeline and marks them as completed.

  Tasks are written as markdown checklists:

      ## Periodic Tasks
      - [ ] Check weather forecast and send a summary
      - [ ] Scan inbox for urgent emails

  Completed tasks are marked:
      - [x] Check weather forecast and send a summary (completed 2026-02-24T10:30:00Z)

  The agent can also manage this file itself — ask it to
  "add a periodic task" and it will update HEARTBEAT.md.

  ## CRONS.json

  Loads `~/.osa/CRONS.json` for structured scheduled jobs. Each job has a
  standard 5-field cron expression and a type:

    - "agent"   — run a natural-language task through the agent loop
    - "command" — execute a shell command (same security checks as shell_execute)
    - "webhook" — make an outbound HTTP request; on_failure can trigger an agent job

  Jobs fire on a 1-minute tick. Cron expressions support:
    - `*`       any value
    - `*/n`     every n-th value
    - `n`       exact value
    - `n,m,...` comma-separated list
    - `n-m`     range (inclusive)

  ## TRIGGERS.json

  Loads `~/.osa/TRIGGERS.json` for event-driven automation. Each trigger
  watches for a named event and fires when the event bus delivers a matching
  payload. Trigger actions support `{{payload}}` and `{{timestamp}}` template
  interpolation.

  Webhooks are received at `POST /api/v1/webhooks/:trigger_id` and
  translated into bus events that triggers match against.

  ## Circuit Breaker

  Any job or trigger that fails 3 consecutive times is auto-disabled.
  Re-enable by editing the JSON file and calling `Scheduler.reload_crons/0`.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.HeartbeatState
  alias OptimalSystemAgent.Events.Bus

  @heartbeat_interval Application.compile_env(
                        :optimal_system_agent,
                        :heartbeat_interval,
                        30 * 60 * 1000
                      )

  @config_dir Application.compile_env(:optimal_system_agent, :config_dir, "~/.osa")

  @circuit_breaker_limit 3
  @webhook_timeout_ms 10_000

  defstruct failures: %{},
            last_run: nil,
            cron_jobs: [],
            trigger_handlers: %{},
            triggers_raw: [],
            heartbeat_started_at: nil

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc "Trigger a heartbeat check manually."
  def heartbeat do
    GenServer.cast(__MODULE__, :heartbeat)
  end

  @doc "Reload CRONS.json and re-register all enabled cron jobs."
  def reload_crons do
    GenServer.cast(__MODULE__, :reload_crons)
  end

  @doc "Return the list of currently loaded cron jobs with their state."
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @doc "Fire a named trigger with a payload map (called by the webhook HTTP endpoint)."
  def fire_trigger(trigger_id, payload) when is_binary(trigger_id) and is_map(payload) do
    GenServer.cast(__MODULE__, {:fire_trigger, trigger_id, payload})
  end

  @doc "Add a new cron job. Validates, persists to CRONS.json, and reloads."
  def add_job(job_map) when is_map(job_map) do
    GenServer.call(__MODULE__, {:add_job, job_map})
  end

  @doc "Remove a cron job by ID."
  def remove_job(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:remove_job, job_id})
  end

  @doc "Enable or disable a cron job."
  def toggle_job(job_id, enabled?) when is_binary(job_id) and is_boolean(enabled?) do
    GenServer.call(__MODULE__, {:toggle_job, job_id, enabled?})
  end

  @doc "Execute a cron job immediately, bypassing schedule check."
  def run_job(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:run_job, job_id}, 35_000)
  end

  @doc "Add a new trigger. Validates, persists to TRIGGERS.json, and reloads."
  def add_trigger(trigger_map) when is_map(trigger_map) do
    GenServer.call(__MODULE__, {:add_trigger, trigger_map})
  end

  @doc "Remove a trigger by ID."
  def remove_trigger(trigger_id) when is_binary(trigger_id) do
    GenServer.call(__MODULE__, {:remove_trigger, trigger_id})
  end

  @doc "Enable or disable a trigger."
  def toggle_trigger(trigger_id, enabled?) when is_binary(trigger_id) and is_boolean(enabled?) do
    GenServer.call(__MODULE__, {:toggle_trigger, trigger_id, enabled?})
  end

  @doc "Return the list of currently loaded triggers with their state."
  def list_triggers do
    GenServer.call(__MODULE__, :list_triggers)
  end

  @doc "Append an unchecked task to HEARTBEAT.md."
  def add_heartbeat_task(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:add_heartbeat_task, text})
  end

  @doc "Return the DateTime of the next heartbeat tick."
  def next_heartbeat_at do
    GenServer.call(__MODULE__, :next_heartbeat_at)
  end

  @doc "Return scheduler status overview."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Get the path to the HEARTBEAT.md file."
  def heartbeat_path do
    Path.expand(Path.join(@config_dir, "HEARTBEAT.md"))
  end

  # ── Init ─────────────────────────────────────────────────────────────

  @impl true
  def init(state) do
    ensure_heartbeat_file()
    schedule_heartbeat()
    schedule_cron_check()

    state = %{state | heartbeat_started_at: DateTime.utc_now()}
    state = load_crons(state)
    state = load_triggers(state)

    Logger.info(
      "Scheduler started — heartbeat every #{div(@heartbeat_interval, 60_000)} min, " <>
        "#{length(state.cron_jobs)} cron job(s), " <>
        "#{map_size(state.trigger_handlers)} trigger(s)"
    )

    {:ok, state}
  end

  # ── Cast Handlers ─────────────────────────────────────────────────────

  @impl true
  def handle_cast(:heartbeat, state) do
    state = run_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reload_crons, state) do
    state = load_crons(state)
    state = load_triggers(state)

    Logger.info(
      "Scheduler reloaded — #{length(state.cron_jobs)} cron job(s), " <>
        "#{map_size(state.trigger_handlers)} trigger(s)"
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:fire_trigger, trigger_id, payload}, state) do
    state = run_trigger(trigger_id, payload, state)
    {:noreply, state}
  end

  # ── Call Handlers ─────────────────────────────────────────────────────

  @impl true
  def handle_call(:list_jobs, _from, state) do
    jobs =
      Enum.map(state.cron_jobs, fn job ->
        failures = Map.get(state.failures, job["id"], 0)

        Map.merge(job, %{
          "failure_count" => failures,
          "circuit_open" => failures >= @circuit_breaker_limit
        })
      end)

    {:reply, jobs, state}
  end

  @impl true
  def handle_call({:add_job, job_map}, _from, state) do
    job =
      job_map
      |> Map.put_new("id", generate_id())
      |> Map.put_new("enabled", true)

    case validate_job(job) do
      :ok ->
        case atomic_update_crons(state, fn jobs -> jobs ++ [job] end) do
          {:ok, state} -> {:reply, {:ok, job}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_job, job_id}, _from, state) do
    if Enum.any?(state.cron_jobs, &(&1["id"] == job_id)) do
      case atomic_update_crons(state, fn jobs ->
             Enum.reject(jobs, &(&1["id"] == job_id))
           end) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Job not found: #{job_id}"}, state}
    end
  end

  @impl true
  def handle_call({:toggle_job, job_id, enabled?}, _from, state) do
    if Enum.any?(state.cron_jobs, &(&1["id"] == job_id)) do
      case atomic_update_crons(state, fn jobs ->
             Enum.map(jobs, fn job ->
               if job["id"] == job_id, do: Map.put(job, "enabled", enabled?), else: job
             end)
           end) do
        {:ok, state} ->
          state =
            if enabled?, do: %{state | failures: Map.delete(state.failures, job_id)}, else: state

          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Job not found: #{job_id}"}, state}
    end
  end

  @impl true
  def handle_call({:run_job, job_id}, _from, state) do
    case Enum.find(state.cron_jobs, &(&1["id"] == job_id)) do
      nil ->
        {:reply, {:error, "Job not found: #{job_id}"}, state}

      job ->
        case execute_cron_job(job) do
          {:ok, result} ->
            state = %{state | failures: Map.delete(state.failures, job_id)}
            {:reply, {:ok, result}, state}

          {:error, reason} ->
            failures = Map.get(state.failures, job_id, 0) + 1
            state = %{state | failures: Map.put(state.failures, job_id, failures)}
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_trigger, trigger_map}, _from, state) do
    trigger =
      trigger_map
      |> Map.put_new("id", generate_id())
      |> Map.put_new("enabled", true)

    case validate_trigger(trigger) do
      :ok ->
        case atomic_update_triggers(state, fn triggers -> triggers ++ [trigger] end) do
          {:ok, state} -> {:reply, {:ok, trigger}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_trigger, trigger_id}, _from, state) do
    if Enum.any?(state.triggers_raw, &(&1["id"] == trigger_id)) do
      case atomic_update_triggers(state, fn triggers ->
             Enum.reject(triggers, &(&1["id"] == trigger_id))
           end) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Trigger not found: #{trigger_id}"}, state}
    end
  end

  @impl true
  def handle_call({:toggle_trigger, trigger_id, enabled?}, _from, state) do
    if Enum.any?(state.triggers_raw, &(&1["id"] == trigger_id)) do
      case atomic_update_triggers(state, fn triggers ->
             Enum.map(triggers, fn t ->
               if t["id"] == trigger_id, do: Map.put(t, "enabled", enabled?), else: t
             end)
           end) do
        {:ok, state} ->
          state =
            if enabled?,
              do: %{state | failures: Map.delete(state.failures, trigger_id)},
              else: state

          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, "Trigger not found: #{trigger_id}"}, state}
    end
  end

  @impl true
  def handle_call(:list_triggers, _from, state) do
    triggers =
      Enum.map(state.triggers_raw, fn trigger ->
        failures = Map.get(state.failures, trigger["id"], 0)

        Map.merge(trigger, %{
          "failure_count" => failures,
          "circuit_open" => failures >= @circuit_breaker_limit
        })
      end)

    {:reply, triggers, state}
  end

  @impl true
  def handle_call({:add_heartbeat_task, text}, _from, state) do
    path = heartbeat_path()

    case File.read(path) do
      {:ok, content} ->
        new_line = "- [ ] #{text}"
        updated = String.trim_trailing(content) <> "\n#{new_line}\n"
        File.write!(path, updated)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, "Failed to read HEARTBEAT.md: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call(:next_heartbeat_at, _from, state) do
    next =
      case state.last_run do
        nil ->
          DateTime.add(
            state.heartbeat_started_at || DateTime.utc_now(),
            @heartbeat_interval,
            :millisecond
          )

        last ->
          DateTime.add(last, @heartbeat_interval, :millisecond)
      end

    {:reply, next, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    enabled_jobs = Enum.count(state.cron_jobs, &(&1["enabled"] == true))
    enabled_triggers = Enum.count(state.triggers_raw, &(&1["enabled"] == true))

    pending_tasks =
      case File.read(heartbeat_path()) do
        {:ok, content} -> length(parse_pending_tasks(content))
        _ -> 0
      end

    next =
      case state.last_run do
        nil ->
          DateTime.add(
            state.heartbeat_started_at || DateTime.utc_now(),
            @heartbeat_interval,
            :millisecond
          )

        last ->
          DateTime.add(last, @heartbeat_interval, :millisecond)
      end

    status = %{
      cron_active: enabled_jobs,
      cron_total: length(state.cron_jobs),
      trigger_active: enabled_triggers,
      trigger_total: length(state.triggers_raw),
      heartbeat_pending: pending_tasks,
      next_heartbeat: next
    }

    {:reply, status, state}
  end

  # ── Info Handlers ─────────────────────────────────────────────────────

  @impl true
  def handle_info(:heartbeat, state) do
    state = run_heartbeat(state)
    schedule_heartbeat()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cron_check, state) do
    state = run_cron_check(state)
    schedule_cron_check()
    {:noreply, state}
  end

  # ── CRONS.json Loading ────────────────────────────────────────────────

  defp crons_path do
    Path.expand(Path.join(@config_dir, "CRONS.json"))
  end

  defp triggers_path do
    Path.expand(Path.join(@config_dir, "TRIGGERS.json"))
  end

  defp load_crons(state) do
    path = crons_path()

    if File.exists?(path) do
      case File.read(path) |> then(fn {:ok, raw} -> Jason.decode(raw) end) do
        {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
          enabled = Enum.filter(jobs, &(&1["enabled"] == true))
          Logger.info("CRONS.json: #{length(enabled)} enabled job(s) out of #{length(jobs)}")
          %{state | cron_jobs: jobs}

        {:error, reason} ->
          Logger.warning("Failed to parse CRONS.json: #{inspect(reason)}")
          state

        _ ->
          Logger.warning("CRONS.json: unexpected format (expected top-level 'jobs' array)")
          state
      end
    else
      Logger.debug("CRONS.json not found at #{path} — skipping")
      state
    end
  rescue
    e ->
      Logger.warning("Error loading CRONS.json: #{Exception.message(e)}")
      state
  end

  defp load_triggers(state) do
    path = triggers_path()

    if File.exists?(path) do
      case File.read(path) |> then(fn {:ok, raw} -> Jason.decode(raw) end) do
        {:ok, %{"triggers" => triggers}} when is_list(triggers) ->
          enabled = Enum.filter(triggers, &(&1["enabled"] == true))

          # Build a map of trigger_id -> trigger for fast lookup
          handler_map =
            enabled
            |> Enum.filter(&is_binary(&1["id"]))
            |> Map.new(&{&1["id"], &1})

          Logger.info(
            "TRIGGERS.json: #{map_size(handler_map)} enabled trigger(s) out of #{length(triggers)}"
          )

          %{state | trigger_handlers: handler_map, triggers_raw: triggers}

        {:error, reason} ->
          Logger.warning("Failed to parse TRIGGERS.json: #{inspect(reason)}")
          state

        _ ->
          Logger.warning("TRIGGERS.json: unexpected format (expected top-level 'triggers' array)")
          state
      end
    else
      Logger.debug("TRIGGERS.json not found at #{path} — skipping")
      state
    end
  rescue
    e ->
      Logger.warning("Error loading TRIGGERS.json: #{Exception.message(e)}")
      state
  end

  # ── Cron Check ────────────────────────────────────────────────────────

  defp run_cron_check(state) do
    now = DateTime.utc_now()

    enabled_jobs =
      state.cron_jobs
      |> Enum.filter(&(&1["enabled"] == true))
      |> Enum.reject(fn job ->
        failures = Map.get(state.failures, job["id"], 0)
        open = failures >= @circuit_breaker_limit

        if open do
          Logger.warning(
            "Cron '#{job["id"]}': circuit breaker open (#{failures} failures) — skipping"
          )
        end

        open
      end)

    firing =
      Enum.filter(enabled_jobs, fn job ->
        case parse_cron_expression(job["schedule"]) do
          {:ok, fields} ->
            cron_matches?(fields, now)

          {:error, reason} ->
            Logger.warning("Cron '#{job["id"]}': bad schedule '#{job["schedule"]}' — #{reason}")
            false
        end
      end)

    if firing != [] do
      Logger.info("Cron tick: #{length(firing)} job(s) firing at #{DateTime.to_iso8601(now)}")
    end

    Enum.reduce(firing, state, fn job, acc ->
      case execute_cron_job(job) do
        {:ok, _} ->
          Logger.info("Cron '#{job["id"]}' (#{job["name"]}): completed")
          %{acc | failures: Map.delete(acc.failures, job["id"])}

        {:error, reason} ->
          failures = Map.get(acc.failures, job["id"], 0) + 1

          Logger.warning(
            "Cron '#{job["id"]}' (#{job["name"]}): failed (#{failures}/#{@circuit_breaker_limit}) — #{reason}"
          )

          if failures >= @circuit_breaker_limit do
            Logger.warning(
              "Cron '#{job["id"]}': circuit breaker opened after #{failures} failures"
            )
          end

          %{acc | failures: Map.put(acc.failures, job["id"], failures)}
      end
    end)
  end

  defp execute_cron_job(%{"type" => "agent", "job" => task} = job) do
    Logger.debug("Cron '#{job["id"]}': running agent task")
    execute_task(task, "cron_#{job["id"]}")
  end

  defp execute_cron_job(%{"type" => "command", "command" => command} = job) do
    Logger.debug("Cron '#{job["id"]}': running command")
    run_shell_command(command)
  end

  defp execute_cron_job(%{"type" => "webhook"} = job) do
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

  defp execute_cron_job(job) do
    {:error, "Unknown job type: #{inspect(job["type"])}"}
  end

  # ── Trigger Execution ─────────────────────────────────────────────────

  defp run_trigger(trigger_id, payload, state) do
    case Map.get(state.trigger_handlers, trigger_id) do
      nil ->
        Logger.debug("Trigger '#{trigger_id}': no matching enabled trigger found")
        state

      trigger ->
        failures = Map.get(state.failures, trigger_id, 0)

        if failures >= @circuit_breaker_limit do
          Logger.warning(
            "Trigger '#{trigger_id}': circuit breaker open (#{failures} failures) — skipping"
          )

          state
        else
          Logger.info("Trigger '#{trigger_id}' (#{trigger["name"]}): firing")

          case execute_trigger_action(trigger, payload) do
            {:ok, _} ->
              Logger.info("Trigger '#{trigger_id}': completed")
              %{state | failures: Map.delete(state.failures, trigger_id)}

            {:error, reason} ->
              new_failures = failures + 1

              Logger.warning(
                "Trigger '#{trigger_id}': failed (#{new_failures}/#{@circuit_breaker_limit}) — #{reason}"
              )

              if new_failures >= @circuit_breaker_limit do
                Logger.warning(
                  "Trigger '#{trigger_id}': circuit breaker opened after #{new_failures} failures"
                )
              end

              %{state | failures: Map.put(state.failures, trigger_id, new_failures)}
          end
        end
    end
  end

  defp execute_trigger_action(%{"type" => "agent", "job" => job_template} = trigger, payload) do
    task = interpolate(job_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running agent task")
    execute_task(task, "trigger_#{trigger["id"]}")
  end

  defp execute_trigger_action(
         %{"type" => "command", "command" => cmd_template} = trigger,
         payload
       ) do
    command = interpolate(cmd_template, payload)
    Logger.debug("Trigger '#{trigger["id"]}': running command")
    run_shell_command(command)
  end

  defp execute_trigger_action(trigger, _payload) do
    {:error, "Unknown trigger type: #{inspect(trigger["type"])}"}
  end

  # ── Template Interpolation ────────────────────────────────────────────

  # Replace {{payload}} with the full payload as JSON,
  # {{timestamp}} with the current ISO 8601 timestamp,
  # and {{payload.key}} with a specific top-level key value.
  # All substituted values are shell-escaped to prevent injection.
  defp interpolate(template, payload) when is_binary(template) and is_map(payload) do
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

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp shell_escape(value), do: shell_escape(to_string(value))

  # ── Shell Command Execution ───────────────────────────────────────────

  # Shell security validation and output limits are centralised in ShellPolicy.
  @max_output_bytes OptimalSystemAgent.Security.ShellPolicy.max_output_bytes()

  defp run_shell_command(command) when is_binary(command) do
    command =
      command
      |> String.replace(~r/\s*&\s*$/, "")
      |> String.replace(~r/^\s*nohup\s+/, "")
      |> String.trim()

    if command == "" do
      {:error, "Blocked: empty command"}
    else
      case OptimalSystemAgent.Security.ShellPolicy.validate(command) do
        :ok ->
          task =
            Task.async(fn ->
              System.cmd("sh", ["-c", command], stderr_to_stdout: true)
            end)

          case Task.yield(task, 30_000) || Task.shutdown(task) do
            {:ok, {output, 0}} ->
              truncated =
                if byte_size(output) > @max_output_bytes do
                  String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
                else
                  output
                end

              {:ok, truncated}

            {:ok, {output, code}} ->
              {:error, "Exit #{code}:\n#{output}"}

            nil ->
              {:error, "Command timed out after 30 seconds"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end


  # ── Outbound HTTP (webhook type) ──────────────────────────────────────

  defp validate_url(url) when is_binary(url) do
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

  defp validate_url(_), do: {:error, :invalid_url}

  defp http_request(method, url, headers, body) do
    :ok = :inets.start(:httpc, profile: :default)

    headers_list =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request =
      case method do
        "GET" -> {String.to_charlist(url), headers_list}
        _ -> {String.to_charlist(url), headers_list, ~c"application/json", body}
      end

    opts = [{:timeout, @webhook_timeout_ms}]

    method_atom =
      case String.downcase(method) do
        "get" -> :get
        "post" -> :post
        "put" -> :put
        "delete" -> :delete
        "patch" -> :patch
        _ -> :get
      end

    case :httpc.request(method_atom, request, opts, []) do
      {:ok, {{_vsn, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "HTTP error: #{Exception.message(e)}"}
  end

  # ── Cron Expression Parsing & Matching ───────────────────────────────

  # Parse a standard 5-field cron expression into a map of field -> allowed values.
  # Supported: * | */n | n | n,m | n-m | combinations like 1,3,5 or 1-5,7
  #
  # Fields: {minute, hour, day_of_month, month, day_of_week}
  # Ranges: minute 0-59, hour 0-23, dom 1-31, month 1-12, dow 0-6 (0=Sunday)
  defp parse_cron_expression(expr) when is_binary(expr) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    case parts do
      [min, hour, dom, month, dow] ->
        with {:ok, min_set} <- parse_cron_field(min, 0, 59),
             {:ok, hour_set} <- parse_cron_field(hour, 0, 23),
             {:ok, dom_set} <- parse_cron_field(dom, 1, 31),
             {:ok, month_set} <- parse_cron_field(month, 1, 12),
             {:ok, dow_set} <- parse_cron_field(dow, 0, 6) do
          {:ok, %{minute: min_set, hour: hour_set, dom: dom_set, month: month_set, dow: dow_set}}
        end

      _ ->
        {:error, "expected 5 fields, got #{length(parts)}"}
    end
  end

  defp parse_cron_expression(_), do: {:error, "schedule must be a string"}

  defp parse_cron_field("*", min, max), do: {:ok, MapSet.new(min..max)}

  defp parse_cron_field("*/" <> step_str, min, max) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        values = Enum.filter(min..max, &(rem(&1 - min, step) == 0))
        {:ok, MapSet.new(values)}

      _ ->
        {:error, "invalid step value: #{step_str}"}
    end
  end

  defp parse_cron_field(field, min, max) do
    # Split by comma to handle lists like "1,3,5" or "1-5,7"
    parts = String.split(field, ",")

    Enum.reduce_while(parts, {:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_cron_single(part, min, max) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_cron_single(part, min, max) do
    cond do
      String.contains?(part, "-") ->
        case String.split(part, "-", parts: 2) do
          [lo_str, hi_str] ->
            with {lo, ""} <- Integer.parse(lo_str),
                 {hi, ""} <- Integer.parse(hi_str),
                 true <- lo >= min and hi <= max and lo <= hi do
              {:ok, MapSet.new(lo..hi)}
            else
              _ -> {:error, "invalid range: #{part}"}
            end

          _ ->
            {:error, "invalid range: #{part}"}
        end

      true ->
        case Integer.parse(part) do
          {n, ""} when n >= min and n <= max ->
            {:ok, MapSet.new([n])}

          {n, ""} ->
            {:error, "value #{n} out of range #{min}-#{max}"}

          _ ->
            {:error, "invalid cron value: #{part}"}
        end
    end
  end

  defp cron_matches?(%{minute: min_s, hour: hr_s, dom: dom_s, month: mo_s, dow: dow_s}, dt) do
    # Date.day_of_week/1 returns 1 (Mon) through 7 (Sun).
    # Cron convention: 0 = Sunday, 1 = Monday ... 6 = Saturday.
    dow =
      case Date.day_of_week(dt) do
        7 -> 0
        n -> n
      end

    MapSet.member?(min_s, dt.minute) and
      MapSet.member?(hr_s, dt.hour) and
      MapSet.member?(dom_s, dt.day) and
      MapSet.member?(mo_s, dt.month) and
      MapSet.member?(dow_s, dow)
  end

  # ── Heartbeat Execution ─────────────────────────────────────────────

  defp run_heartbeat(state) do
    # Check quiet hours — suppress heartbeat if active
    quiet =
      try do
        HeartbeatState.in_quiet_hours?()
      catch
        :exit, _ -> false
      end

    if quiet do
      Logger.debug("[Scheduler] Heartbeat suppressed — quiet hours active")
      return = %{state | last_run: DateTime.utc_now()}

      try do
        HeartbeatState.record_check(:heartbeat, :suppressed_quiet_hours)
      catch
        :exit, _ -> :ok
      end

      return
    else
      run_heartbeat_tasks(state)
    end
  end

  defp run_heartbeat_tasks(state) do
    path = heartbeat_path()

    if File.exists?(path) do
      content = File.read!(path)
      tasks = parse_pending_tasks(content)

      if tasks == [] do
        Logger.debug("Heartbeat: no pending tasks")
        %{state | last_run: DateTime.utc_now()}
      else
        Logger.info("Heartbeat: #{length(tasks)} pending task(s)")

        Bus.emit(:system_event, %{
          event: :heartbeat_started,
          task_count: length(tasks)
        })

        {completed, state} =
          Enum.reduce(tasks, {[], state}, fn task, {done, acc} ->
            failures = Map.get(acc.failures, task, 0)

            if failures >= @circuit_breaker_limit do
              Logger.warning(
                "Heartbeat: skipping '#{task}' — circuit breaker open (#{failures} failures)"
              )

              {done, acc}
            else
              case execute_task(task, "heartbeat_#{System.system_time(:second)}") do
                {:ok, _result} ->
                  Logger.info("Heartbeat: completed '#{task}'")
                  {[task | done], %{acc | failures: Map.delete(acc.failures, task)}}

                {:error, reason} ->
                  Logger.warning("Heartbeat: failed '#{task}' — #{reason}")
                  {done, %{acc | failures: Map.put(acc.failures, task, failures + 1)}}
              end
            end
          end)

        if completed != [] do
          updated = mark_completed(content, completed)
          File.write!(path, updated)
        end

        Bus.emit(:system_event, %{
          event: :heartbeat_completed,
          completed: length(completed),
          total: length(tasks)
        })

        result = %{completed: length(completed), total: length(tasks)}

        try do
          HeartbeatState.record_check(:heartbeat, result)
        catch
          :exit, _ -> :ok
        end

        %{state | last_run: DateTime.utc_now()}
      end
    else
      %{state | last_run: DateTime.utc_now()}
    end
  end

  defp execute_task(task_description, session_id) do
    case DynamicSupervisor.start_child(
           OptimalSystemAgent.Channels.Supervisor,
           {Loop, session_id: session_id, channel: :heartbeat}
         ) do
      {:ok, _pid} ->
        result = Loop.process_message(session_id, task_description)

        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] -> GenServer.stop(pid, :normal)
          _ -> :ok
        end

        case result do
          {:ok, response} -> {:ok, response}
          {:filtered, _signal} -> {:ok, "filtered"}
          {:error, reason} -> {:error, to_string(reason)}
        end

      {:error, reason} ->
        {:error, "Failed to start agent loop: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── HEARTBEAT.md Parsing ────────────────────────────────────────────

  defp parse_pending_tasks(content) do
    content
    |> String.replace(~r/<!--[\s\S]*?-->/, "")
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\s*-\s*\[\s*\]\s*.+/))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*-\s*\[\s*\]\s*/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp mark_completed(content, completed_tasks) do
    Enum.reduce(completed_tasks, content, fn task, acc ->
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      pattern = ~r/(-\s*)\[\s*\](\s*#{Regex.escape(task)})/
      replacement = "\\1[x]\\2 (completed #{timestamp})"
      String.replace(acc, pattern, replacement, global: false)
    end)
  end

  # ── Atomic JSON Writes ──────────────────────────────────────────────

  defp atomic_update_crons(state, update_fn) do
    path = crons_path()
    tmp_path = path <> ".tmp"

    current_jobs =
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, %{"jobs" => jobs}} -> jobs
            _ -> state.cron_jobs
          end

        _ ->
          state.cron_jobs
      end

    updated_jobs = update_fn.(current_jobs)
    json = Jason.encode!(%{"jobs" => updated_jobs}, pretty: true)

    with :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      state = load_crons(%{state | cron_jobs: []})
      {:ok, state}
    else
      {:error, reason} -> {:error, "Failed to write CRONS.json: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to update CRONS.json: #{Exception.message(e)}"}
  end

  defp atomic_update_triggers(state, update_fn) do
    path = triggers_path()
    tmp_path = path <> ".tmp"

    current_triggers =
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, %{"triggers" => triggers}} -> triggers
            _ -> state.triggers_raw
          end

        _ ->
          state.triggers_raw
      end

    updated_triggers = update_fn.(current_triggers)
    json = Jason.encode!(%{"triggers" => updated_triggers}, pretty: true)

    with :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      state = load_triggers(%{state | trigger_handlers: %{}, triggers_raw: []})
      {:ok, state}
    else
      {:error, reason} -> {:error, "Failed to write TRIGGERS.json: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to update TRIGGERS.json: #{Exception.message(e)}"}
  end

  # ── Validation ─────────────────────────────────────────────────────

  defp validate_job(job) do
    cond do
      not is_binary(job["name"]) or job["name"] == "" ->
        {:error, "Job must have a non-empty 'name'"}

      not is_binary(job["schedule"]) ->
        {:error, "Job must have a 'schedule' (cron expression)"}

      job["type"] not in ["agent", "command", "webhook"] ->
        {:error, "Job 'type' must be one of: agent, command, webhook"}

      job["type"] == "agent" and (not is_binary(job["job"]) or job["job"] == "") ->
        {:error, "Agent job must have a 'job' field with the task description"}

      job["type"] == "command" and (not is_binary(job["command"]) or job["command"] == "") ->
        {:error, "Command job must have a 'command' field"}

      job["type"] == "webhook" and (not is_binary(job["url"]) or job["url"] == "") ->
        {:error, "Webhook job must have a 'url' field"}

      true ->
        case parse_cron_expression(job["schedule"]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Invalid cron schedule: #{reason}"}
        end
    end
  end

  defp validate_trigger(trigger) do
    cond do
      not is_binary(trigger["name"]) or trigger["name"] == "" ->
        {:error, "Trigger must have a non-empty 'name'"}

      not is_binary(trigger["event"]) or trigger["event"] == "" ->
        {:error, "Trigger must have an 'event' field"}

      trigger["type"] not in ["agent", "command"] ->
        {:error, "Trigger 'type' must be one of: agent, command"}

      trigger["type"] == "agent" and (not is_binary(trigger["job"]) or trigger["job"] == "") ->
        {:error, "Agent trigger must have a 'job' field"}

      trigger["type"] == "command" and
          (not is_binary(trigger["command"]) or trigger["command"] == "") ->
        {:error, "Command trigger must have a 'command' field"}

      true ->
        :ok
    end
  end

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()

  # ── Helpers ─────────────────────────────────────────────────────────

  defp ensure_heartbeat_file do
    path = heartbeat_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    unless File.exists?(path) do
      File.write!(path, """
      # Heartbeat Tasks

      Add tasks here as a markdown checklist. OSA checks this file every #{div(@heartbeat_interval, 60_000)} minutes
      and executes any unchecked items through the agent loop.

      ## Periodic Tasks

      <!-- Example tasks (uncomment to activate):
      - [ ] Check for new emails and summarize urgent ones
      - [ ] Review today's calendar and prepare a briefing
      -->
      """)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp schedule_cron_check do
    Process.send_after(self(), :cron_check, 60_000)
  end
end
