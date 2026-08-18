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
  alias OptimalSystemAgent.Agent.StayAwake
  alias OptimalSystemAgent.Agent.Scheduler.CronPresets
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.System.AtomicFile

  defp heartbeat_interval,
    do: Application.get_env(:optimal_system_agent, :heartbeat_interval, 1_800_000)

  @circuit_breaker_limit 3

  # Cron ticks are armed on a FIXED cadence; a tick's own work never delays the
  # next one (see `handle_info(:cron_check, ...)`).
  @cron_tick_ms 60_000

  # Ceiling on how many missed minutes one tick will backfill. A machine
  # suspended for a week must not replay ten thousand minutes of cron at once;
  # past this the skip is reported rather than replayed.
  @max_backfill_minutes 60

  # Default ceiling on a single job execution before the scheduler terminates it
  # (30 min). Distinct from the caller-facing reply deadline below.
  @default_job_timeout_ms 1_800_000

  # How long a `run_job/1` caller is made to wait before being told the job is
  # still going. The job itself keeps running under its own deadline; the
  # in-flight set is what stops the caller's retry from starting a second copy.
  @default_run_job_reply_ms 30_000

  defstruct failures: %{},
            last_run: nil,
            cron_jobs: [],
            trigger_handlers: %{},
            triggers_raw: [],
            heartbeat_started_at: nil,
            # Executions currently running OFF this process, `job_id => entry`.
            # Its only job is to make a second concurrent execution of the same
            # job impossible.
            in_flight: %{},
            # `task_ref => job_id`, the reverse index for task replies/DOWNs.
            by_ref: %{},
            # Last wall-clock minute the cron matcher actually evaluated. Any
            # gap between this and `now` is a missed tick, and is backfilled or
            # explicitly reported — never silently skipped.
            last_cron_minute: nil,
            # Real armed-timer instants, so `status/0` reports when the next
            # tick will ACTUALLY happen rather than deriving it from `last_run`.
            next_heartbeat_at: nil,
            next_cron_at: nil

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

    state = %{state | heartbeat_started_at: DateTime.utc_now()}
    state = schedule_heartbeat(state)
    state = schedule_cron_check(state)
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

  # Never runs the job body on this process. The caller is parked and answered
  # when the execution task reports back (or when the reply deadline expires),
  # so a long job cannot serialize `list_jobs`, `add_job`, or the cron tick
  # behind it.
  @impl true
  def handle_call({:run_job, job_id}, from, state) do
    case Enum.find(state.cron_jobs, &(&1["id"] == job_id)) do
      nil ->
        {:reply, {:error, "Job not found: #{job_id}"}, state}

      job ->
        case start_job(state, job, from) do
          {:started, state} ->
            {:noreply, state}

          {:already_running, state} ->
            # The previous execution is still going. Answering with an error is
            # the honest result; starting a second copy (what an unbounded
            # handler plus a caller-side retry produced) is not.
            {:reply, {:error, :already_running}, state}

          {:error, reason, state} ->
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
        AtomicFile.write!(path, updated)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, "Failed to read HEARTBEAT.md: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call(:next_heartbeat_at, _from, state) do
    {:reply, next_heartbeat(state), state}
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

    status = %{
      cron_active: enabled_jobs,
      cron_total: length(state.cron_jobs),
      trigger_active: enabled_triggers,
      trigger_total: length(state.triggers_raw),
      heartbeat_pending: pending_tasks,
      next_heartbeat: next_heartbeat(state),
      next_cron_check: state.next_cron_at,
      # Truth about what is executing right now, so "0 running" is never
      # reported for a job the scheduler is in fact still waiting on.
      cron_running: Map.keys(state.in_flight),
      last_cron_minute: state.last_cron_minute
    }

    {:reply, status, state}
  end

  # The instant the armed timer will actually fire. Falls back to a derived
  # value only before the first arm.
  defp next_heartbeat(%{next_heartbeat_at: %DateTime{} = at}), do: at

  defp next_heartbeat(state) do
    DateTime.add(
      state.heartbeat_started_at || DateTime.utc_now(),
      heartbeat_interval(),
      :millisecond
    )
  end

  # ── Info Handlers ─────────────────────────────────────────────────────

  @impl true
  def handle_info(:retry_register_bus_triggers, state) do
    {:noreply, state, {:continue, :register_bus_triggers}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Re-arm before running, so the heartbeat cadence is a property of the
    # clock rather than of how long the last batch took.
    state = schedule_heartbeat(state)
    {:noreply, run_heartbeat(state)}
  end

  @impl true
  def handle_info(:cron_check, state) do
    # Re-armed FIRST and on a fixed cadence. Previously the next tick was armed
    # only AFTER the firing jobs had run inline, so every minute spent
    # executing was a minute the matcher never evaluated — those jobs simply
    # never fired, with no log and no backfill.
    state = schedule_cron_check(state)
    reconcile_stay_awake(state)
    {:noreply, run_cron_check(state)}
  end

  # An execution task finished. `async_nolink` delivers the value first and the
  # :DOWN afterwards; flushing the monitor here means the DOWN never arrives.
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.by_ref, ref) do
      {:ok, job_id} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_job(state, job_id, normalize_result(result))}

      :error ->
        {:noreply, state}
    end
  end

  # The task died without reporting — a crash in the job body. Counted as a
  # failure exactly once, by ref, so a crashed job cannot be double-counted.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.by_ref, ref) do
      {:ok, job_id} ->
        {:noreply, finish_job(state, job_id, {:error, "job crashed: #{inspect(reason)}"})}

      :error ->
        {:noreply, state}
    end
  end

  # Server-side execution deadline. The handler used to be unbounded: a job
  # that never returned held the scheduler forever and the caller's own 35s
  # client timeout just made a retry (i.e. a second concurrent execution)
  # likely. Now the execution is terminated and recorded once.
  @impl true
  def handle_info({:job_deadline, ref}, state) do
    case Map.fetch(state.by_ref, ref) do
      {:ok, job_id} ->
        entry = Map.get(state.in_flight, job_id, %{})
        Logger.warning("Cron '#{job_id}': exceeded #{job_timeout_ms()}ms — terminating execution")
        terminate_task(entry)
        Process.demonitor(ref, [:flush])
        {:noreply, finish_job(state, job_id, {:error, :timeout})}

      :error ->
        {:noreply, state}
    end
  end

  # The caller of `run_job/1` has waited long enough. The JOB is not touched —
  # it keeps running under its own deadline — the caller is simply told so.
  @impl true
  def handle_info({:reply_deadline, ref}, state) do
    with {:ok, job_id} <- Map.fetch(state.by_ref, ref),
         %{from: from} = entry when not is_nil(from) <- Map.get(state.in_flight, job_id) do
      GenServer.reply(from, {:error, :still_running})
      in_flight = Map.put(state.in_flight, job_id, %{entry | from: nil})
      {:noreply, %{state | in_flight: in_flight}}
    else
      _ -> {:noreply, state}
    end
  end

  # Stray messages must not crash the scheduler — it owns every cron job on the
  # machine.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

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

  # Evaluate every minute that has elapsed since the last evaluation, not just
  # `now`. A tick that arrives late (GC pause, machine suspend, a scheduler
  # busy with something else) used to skip every intervening minute silently.
  @doc false
  @spec run_cron_check(%__MODULE__{}) :: %__MODULE__{}
  def run_cron_check(state) do
    now = DateTime.utc_now()
    {minutes, skipped} = pending_minutes(state.last_cron_minute, now)

    if skipped > 0 do
      Logger.error(
        "[Scheduler] cron tick gap: #{skipped} minute(s) elapsed beyond the " <>
          "#{@max_backfill_minutes}-minute backfill window and were NOT evaluated — any job " <>
          "scheduled in that window did not run"
      )
    end

    state = %{state | last_cron_minute: truncate_minute(now)}
    Enum.reduce(minutes, state, &fire_due_jobs(&2, &1))
  end

  # Minutes still owed evaluation, oldest first, plus how many were dropped for
  # exceeding the backfill window.
  defp pending_minutes(nil, now), do: {[truncate_minute(now)], 0}

  defp pending_minutes(last, now) do
    current = truncate_minute(now)

    case DateTime.diff(current, last, :second) |> div(60) do
      n when n <= 0 ->
        # Clock went backwards, or two ticks landed in the same minute. Do not
        # re-fire a minute already evaluated.
        {[], 0}

      n when n <= @max_backfill_minutes ->
        {for(i <- 1..n, do: DateTime.add(last, i * 60, :second)), 0}

      n ->
        {for(i <- (n - @max_backfill_minutes + 1)..n, do: DateTime.add(last, i * 60, :second)),
         n - @max_backfill_minutes}
    end
  end

  defp truncate_minute(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> Map.put(:second, 0) |> Map.put(:microsecond, {0, 0})
  end

  defp fire_due_jobs(state, minute) do
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
            cron_matches?(fields, minute)

          {:error, reason} ->
            Logger.warning("Cron '#{job["id"]}': bad schedule '#{job["schedule"]}' — #{reason}")
            false
        end
      end)

    if firing != [] do
      Logger.info("Cron tick: #{length(firing)} job(s) firing at #{DateTime.to_iso8601(minute)}")
    end

    Enum.reduce(firing, state, fn job, acc ->
      case start_job(acc, job, nil) do
        {:started, acc} ->
          acc

        {:already_running, acc} ->
          acc

        {:error, reason, acc} ->
          Logger.warning("Cron '#{job["id"]}': could not dispatch — #{inspect(reason)}")
          acc
      end
    end)
  end

  # ── Off-process execution ─────────────────────────────────────────────
  #
  # The scheduler NEVER runs a job body. It routes: each execution is a
  # supervised task, and the scheduler only records the outcome. An `"agent"`
  # job is a full agent turn, and running one inline blocked every other call,
  # cast, and cron tick for its entire duration.

  defp start_job(state, job, from) do
    job_id = job["id"]

    if Map.has_key?(state.in_flight, job_id) do
      Logger.warning(
        "Cron '#{job_id}': previous execution still running — not starting a second one"
      )

      {:already_running, state}
    else
      do_start_job(state, job, job_id, from)
    end
  end

  defp do_start_job(state, job, job_id, from) do
    task =
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
        execute_cron_job(job)
      end)

    job_timer = Process.send_after(self(), {:job_deadline, task.ref}, job_timeout_ms())

    reply_timer =
      if from, do: Process.send_after(self(), {:reply_deadline, task.ref}, run_job_reply_ms())

    entry = %{
      ref: task.ref,
      pid: task.pid,
      from: from,
      job_timer: job_timer,
      reply_timer: reply_timer,
      started_at: DateTime.utc_now()
    }

    {:started,
     %{
       state
       | in_flight: Map.put(state.in_flight, job_id, entry),
         by_ref: Map.put(state.by_ref, task.ref, job_id)
     }}
  rescue
    e -> {:error, Exception.message(e), state}
  catch
    :exit, reason -> {:error, {:exit, reason}, state}
  end

  # Record an execution's outcome exactly once: cancel its timers, drop it from
  # the in-flight set, answer a parked caller, and move the failure counter.
  defp finish_job(state, job_id, result) do
    entry = Map.get(state.in_flight, job_id, %{})
    cancel_timer(Map.get(entry, :job_timer))
    cancel_timer(Map.get(entry, :reply_timer))

    state = %{
      state
      | in_flight: Map.delete(state.in_flight, job_id),
        by_ref: Map.delete(state.by_ref, Map.get(entry, :ref))
    }

    state =
      case result do
        {:ok, value} ->
          Logger.info("Cron '#{job_id}': completed")
          maybe_reply(entry, {:ok, value})
          %{state | failures: Map.delete(state.failures, job_id)}

        {:error, reason} ->
          failures = Map.get(state.failures, job_id, 0) + 1

          Logger.warning(
            "Cron '#{job_id}': failed (#{failures}/#{@circuit_breaker_limit}) — #{inspect(reason)}"
          )

          if failures >= @circuit_breaker_limit do
            Logger.warning("Cron '#{job_id}': circuit breaker opened after #{failures} failures")
          end

          maybe_reply(entry, {:error, reason})
          %{state | failures: Map.put(state.failures, job_id, failures)}
      end

    state
  end

  defp maybe_reply(%{from: from}, reply) when not is_nil(from), do: GenServer.reply(from, reply)
  defp maybe_reply(_entry, _reply), do: :ok

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_), do: :ok

  defp terminate_task(%{pid: pid}) when is_pid(pid) do
    Task.Supervisor.terminate_child(OptimalSystemAgent.TaskSupervisor, pid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp terminate_task(_), do: :ok

  # A job body may return anything; only the two documented shapes are outcomes.
  defp normalize_result({:ok, _} = ok), do: ok
  defp normalize_result({:error, _} = err), do: err
  defp normalize_result(other), do: {:error, "unexpected job result: #{inspect(other)}"}

  @doc "Ceiling on one job execution before the scheduler terminates it."
  @spec job_timeout_ms() :: pos_integer()
  def job_timeout_ms do
    Application.get_env(:optimal_system_agent, :cron_job_timeout_ms, @default_job_timeout_ms)
  end

  @doc "How long a `run_job/1` caller waits before being told the job is still running."
  @spec run_job_reply_ms() :: pos_integer()
  def run_job_reply_ms do
    Application.get_env(
      :optimal_system_agent,
      :cron_run_job_reply_ms,
      @default_run_job_reply_ms
    )
  end

  # Execution seam, mirroring `Heartbeat.run/2`'s injectable executor: tests
  # drive the tick and the in-flight bookkeeping without entering the real tool
  # registry (an `"agent"` job is a full agent turn, a `"command"` job goes
  # through `shell_execute`). Production leaves it unset.
  defp execute_cron_job(job) do
    case Application.get_env(:optimal_system_agent, :cron_executor) do
      fun when is_function(fun, 1) -> fun.(job)
      _ -> JobExecutor.execute_cron_job(job)
    end
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

  # Both schedulers record the instant they actually armed for, so `status/0`
  # and `next_heartbeat_at/0` report the real next tick instead of deriving one
  # from `last_run + interval` — a derivation that drifted from reality the
  # moment a tick took any time at all.
  defp schedule_heartbeat(state) do
    interval = heartbeat_interval()
    Process.send_after(self(), :heartbeat, interval)
    %{state | next_heartbeat_at: DateTime.add(DateTime.utc_now(), interval, :millisecond)}
  end

  defp schedule_cron_check(state) do
    Process.send_after(self(), :cron_check, @cron_tick_ms)
    %{state | next_cron_at: DateTime.add(DateTime.utc_now(), @cron_tick_ms, :millisecond)}
  end
  # ── Keeping the machine awake for work that fires on its own ──────────
  #
  # `Agent.StayAwake` holds an OS sleep inhibitor for the length of a TURN, which
  # is enough for a task someone is waiting on. It is not enough for a proactive
  # agent: a cron due at 3am, or a heartbeat 30 minutes out, spends almost all of
  # its life between turns, and a laptop that idles out in that gap simply never
  # fires the job.
  #
  # The backfill ceiling above (@max_backfill_minutes) is the symptom of exactly
  # this — it exists because the machine DOES suspend and ticks DO get missed.
  # Backfill replays at most an hour; a night of sleep silently drops the rest.
  # Holding the inhibitor while proactive work is configured stops the ticks
  # being missed in the first place.
  #
  # Scoped to real work, deliberately: the hold is taken only when the operator
  # has an ENABLED cron job, an ENABLED trigger, or an unchecked HEARTBEAT.md
  # task. Configuring one of those IS the opt-in — nobody schedules a 3am job and
  # then wants the machine asleep at 3am. With none configured the hold is
  # released, so OSA does not keep a laptop awake for a scheduler that has
  # nothing to do.
  #
  # Reconciled on the one-minute tick rather than on every mutation: acquire and
  # release are both idempotent, so a single convergent check cannot drift out of
  # step the way a dozen mutation sites would.
  @proactive_holder "scheduler:proactive"

  defp reconcile_stay_awake(state) do
    if proactive_work?(state) do
      StayAwake.acquire(@proactive_holder)
    else
      StayAwake.release(@proactive_holder)
    end

    :ok
  rescue
    # Never let keeping the machine awake be the reason a tick fails.
    _ -> :ok
  end

  @doc """
  Whether anything is configured that must fire without a person present.

  Enabled cron jobs, enabled triggers, or an unchecked HEARTBEAT.md task.
  """
  @spec proactive_work?(%__MODULE__{}) :: boolean()
  def proactive_work?(%__MODULE__{} = state) do
    any_enabled?(state.cron_jobs) or any_enabled?(state.triggers_raw) or
      pending_heartbeat_task?()
  end

  # A missing "enabled" key means enabled: `add_job/1` only puts the default in
  # on the way through, and a hand-edited CRONS.json may omit it entirely.
  defp any_enabled?(entries) when is_list(entries) do
    Enum.any?(entries, fn
      %{"enabled" => false} -> false
      %{} -> true
      _ -> false
    end)
  end

  defp any_enabled?(_), do: false

  defp pending_heartbeat_task? do
    case File.read(heartbeat_path()) do
      {:ok, contents} -> String.contains?(contents, "- [ ]")
      _ -> false
    end
  end

end
