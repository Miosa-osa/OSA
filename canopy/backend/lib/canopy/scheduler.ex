defmodule Canopy.Scheduler do
  @moduledoc """
  Quantum-based cron scheduler for agent heartbeats.

  On boot, loads all enabled schedules from the DB and creates Quantum jobs.
  When schedules are created/updated/deleted via the API, the scheduler
  is notified to add/remove/update jobs dynamically.
  """
  use Quantum, otp_app: :canopy

  require Logger
  alias Canopy.Repo
  alias Canopy.Schemas.Schedule
  import Ecto.Query

  @doc "Load all enabled schedules from DB and register as Quantum jobs."
  def load_schedules do
    schedules =
      Repo.all(
        from s in Schedule,
          where: s.enabled == true,
          preload: [:agent]
      )

    for schedule <- schedules do
      add_schedule(schedule)
    end

    Logger.info("[Scheduler] Loaded #{length(schedules)} schedules from database")
  end

  @doc "Add or update a schedule as a Quantum job."
  def add_schedule(%Schedule{} = schedule) do
    job_name = schedule_job_name(schedule.id)

    case Crontab.CronExpression.Parser.parse(schedule.cron_expression) do
      {:ok, cron} ->
        job =
          Quantum.Job.new(__MODULE__)
          |> Quantum.Job.set_name(job_name)
          |> Quantum.Job.set_schedule(cron)
          |> Quantum.Job.set_timezone(schedule.timezone || "UTC")
          |> Quantum.Job.set_task(fn -> execute_schedule(schedule.id) end)

        # Remove existing if any, then add
        delete_job(job_name)
        add_job(job)

        Logger.debug(
          "[Scheduler] Registered job #{job_name} with cron #{schedule.cron_expression}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[Scheduler] Invalid cron '#{schedule.cron_expression}' for schedule #{schedule.id}: #{inspect(reason)}"
        )

        {:error, :invalid_cron}
    end
  end

  @doc "Remove a schedule's Quantum job."
  def remove_schedule(schedule_id) do
    delete_job(schedule_job_name(schedule_id))
  end

  defp schedule_job_name(schedule_id), do: String.to_atom("schedule_#{schedule_id}")

  defp execute_schedule(schedule_id) do
    case Repo.get(Schedule, schedule_id) |> Repo.preload(:agent) do
      nil ->
        Logger.warning("[Scheduler] Schedule #{schedule_id} not found — removing job")
        remove_schedule(schedule_id)

      %Schedule{enabled: false} ->
        Logger.debug("[Scheduler] Schedule #{schedule_id} is disabled — skipping")

      schedule ->
        Logger.info(
          "[Scheduler] Firing heartbeat for agent #{schedule.agent.name} (schedule: #{schedule.name})"
        )

        # Update last_run_at
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        schedule
        |> Ecto.Changeset.change(last_run_at: now, last_run_status: "running")
        |> Repo.update!()

        # Execute via HeartbeatRunner (async)
        Task.Supervisor.start_child(Canopy.HeartbeatRunner, fn ->
          case Canopy.Heartbeat.run(schedule.agent_id,
                 schedule_id: schedule.id,
                 context: schedule.context || "Scheduled heartbeat: #{schedule.name}"
               ) do
            {:ok, session_id} ->
              schedule
              |> Ecto.Changeset.change(last_run_status: "success")
              |> Repo.update()

              Logger.info("[Scheduler] Heartbeat completed: session #{session_id}")

            {:error, reason} ->
              schedule
              |> Ecto.Changeset.change(last_run_status: "failed")
              |> Repo.update()

              Logger.error("[Scheduler] Heartbeat failed: #{inspect(reason)}")
          end
        end)
    end
  end
end
