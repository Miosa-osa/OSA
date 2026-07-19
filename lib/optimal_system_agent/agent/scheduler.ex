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

  alias OptimalSystemAgent.Agent.Scheduler.{CronEngine, Persistence, JobExecutor, Heartbeat}
  alias OptimalSystemAgent.Agent.Scheduler.CronPresets
  alias OptimalSystemAgent.Events.Bus

  defp heartbeat_interval,
    do: Application.get_env(:optimal_system_agent, :heartbeat_interval, 1_800_000)

  @circuit_breaker_limit 3

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
  def heartbeat_path, do: Heartbeat.path()

  # ── Init ─────────────────────────────────────────────────────────────

  @impl true
  def init(state) do
    Heartbeat.ensure_heartbeat_file()
    schedule_heartbeat()
    schedule_cron_check()

    state = %{state | heartbeat_started_at: DateTime.utc_now()}
    state = load_crons(state)
    state = load_trigger_state(state)

    Logger.info(
      "Scheduler started — heartbeat every #{div(heartbeat_interval(), 60_000)} min, " <>
        "#{length(state.cron_jobs)} cron job(s), " <>
        "#{map_size(state.trigger_handlers)} trigger(s)"
    )

    {:ok, state, {:continue, :register_bus_triggers}}
  end

  # Registering triggers with Events.Bus is deferred to handle_continue so a
  # boot-time hiccup there — e.g. Bus transiently unreachable while
  # Infrastructure is still settling under load — degrades the bus-trigger
  # bridge instead of crashing the Scheduler, which would otherwise take
  # down the whole AgentServices supervisor (and hence the entire app).
  @impl true
  def handle_continue(:register_bus_triggers, state) do
    try do
      register_event_triggers(state.triggers_raw)
      {:noreply, state}
    catch
      :exit, reason ->
        Logger.warning("[Scheduler] Events.Bus unavailable, will retry: #{inspect(reason)}")
        Process.send_after(self(), :retry_register_bus_triggers, 500)
        {:noreply, state}
    end
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
      |> normalize_job_schedule()
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
            heartbeat_interval(),
            :millisecond
          )

        last ->
          DateTime.add(last, heartbeat_interval(), :millisecond)
      end

    {:reply, next, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    enabled_jobs = Enum.count(state.cron_jobs, &(&1["enabled"] == true))
    enabled_triggers = Enum.count(state.triggers_raw, &(&1["enabled"] == true))

    pending_tasks =
      case File.read(heartbeat_path()) do
        {:ok, content} -> length(Heartbeat.parse_pending_tasks(content))
        _ -> 0
      end

    next =
      case state.last_run do
        nil ->
          DateTime.add(
            state.heartbeat_started_at || DateTime.utc_now(),
            heartbeat_interval(),
            :millisecond
          )

        last ->
          DateTime.add(last, heartbeat_interval(), :millisecond)
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
  def handle_info(:retry_register_bus_triggers, state) do
    {:noreply, state, {:continue, :register_bus_triggers}}
  end

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

  # ── CRONS/TRIGGERS I/O (delegated to Scheduler.Persistence) ────────
  defp load_crons(state), do: Persistence.load_crons(state)

  # Loads trigger state only — used at init/1, where bus registration is
  # deferred to handle_continue(:register_bus_triggers, ...) instead.
  defp load_trigger_state(state), do: Persistence.load_triggers(state)

  defp load_triggers(state) do
    state = Persistence.load_triggers(state)
    register_event_triggers(state.triggers_raw)
    state
  end

  # ── Bus→Trigger Bridge ──────────────────────────────────────────────
  # Registers bus event handlers for triggers that have an "event" field.
  # When a bus event fires, the matching trigger is invoked automatically.

  defp register_event_triggers(triggers) do
    # Unregister old handlers
    for {event_type, ref} <- Process.get(:trigger_bus_refs, []) do
      Bus.unregister_handler(event_type, ref)
    end

    refs =
      for trigger <- triggers,
          trigger["enabled"] != false,
          event = trigger["event"],
          is_binary(event) and event != "",
          reduce: [] do
        acc ->
          # Use to_existing_atom to prevent atom table exhaustion from
          # user-supplied event names. Only known event atoms are valid.
          event_atom =
            try do
              String.to_existing_atom(event)
            rescue
              ArgumentError -> nil
            end

          if event_atom do
            ref =
              Bus.register_handler(event_atom, fn payload ->
                __MODULE__.fire_trigger(trigger["id"], payload)
              end)

            [{event_atom, ref} | acc]
          else
            Logger.warning(
              "[Scheduler] Unknown event '#{event}' — skipping trigger #{trigger["id"]}"
            )

            acc
          end
      end

    Process.put(:trigger_bus_refs, refs)
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

  defp execute_cron_job(job), do: JobExecutor.execute_cron_job(job)

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

  defp execute_trigger_action(trigger, payload),
    do: JobExecutor.execute_trigger_action(trigger, payload)

  # ── Cron Expression Parsing & Matching ───────────────────────────────
  # Delegated to Scheduler.CronEngine

  defp parse_cron_expression(expr), do: CronEngine.parse(expr)
  defp cron_matches?(fields, dt), do: CronEngine.matches?(fields, dt)

  # ── Heartbeat Execution (delegated to Scheduler.Heartbeat) ──────────

  defp run_heartbeat(state), do: Heartbeat.run(state)

  # ── Atomic writes & validation (delegated to Scheduler.Persistence) ──
  defp atomic_update_crons(state, update_fn), do: Persistence.update_crons(state, update_fn)
  defp atomic_update_triggers(state, update_fn), do: Persistence.update_triggers(state, update_fn)
  defp validate_job(job), do: Persistence.validate_job(job)
  defp validate_trigger(trigger), do: Persistence.validate_trigger(trigger)

  defp normalize_job_schedule(%{"schedule" => schedule} = job) do
    case CronPresets.resolve(schedule) do
      {:ok, cron} -> Map.put(job, "schedule", cron)
      {:error, _reason} -> job
    end
  end

  defp normalize_job_schedule(job), do: job

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()

  # ── Helpers ─────────────────────────────────────────────────────────

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, heartbeat_interval())
  end

  defp schedule_cron_check do
    Process.send_after(self(), :cron_check, 60_000)
  end
end
