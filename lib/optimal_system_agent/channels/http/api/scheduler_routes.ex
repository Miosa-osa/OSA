defmodule OptimalSystemAgent.Channels.HTTP.API.SchedulerRoutes do
  @moduledoc """
  CRUD + trigger + run history for scheduled tasks.
  Forwarded from /scheduled-tasks in the main API router.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Agent.Scheduler.{HeartbeatExecutor, CronPresets}

  plug(:match)
  plug(:dispatch)

  # ── GET /presets — available cron presets (before /:id catch) ─────

  get "/presets" do
    presets =
      CronPresets.list_presets()
      |> Enum.map(fn preset ->
        Map.put(preset, :next_run, format_datetime(CronPresets.next_run(preset.cron)))
      end)

    body = Jason.encode!(%{status: "ok", presets: presets})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # ── GET / — list all scheduled tasks ─────────────────────────────

  get "/" do
    try do
      jobs = Scheduler.list_jobs()

      body =
        Jason.encode!(%{
          status: "ok",
          tasks: Enum.map(jobs, &format_task/1),
          count: length(jobs)
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── POST / — create scheduled task ──────────────────────────────

  post "/" do
    try do
      with %{"name" => name} when is_binary(name) and name != "" <- conn.body_params do
        cron = conn.body_params["cron"] || conn.body_params["schedule"] || "0 * * * *"
        prompt = conn.body_params["prompt"] || conn.body_params["job"] || name
        agent_name = conn.body_params["agent_name"]
        timeout_ms = conn.body_params["timeout_ms"]

        job = %{
          "name" => name,
          "schedule" => cron,
          "type" => "agent",
          "job" => prompt,
          "enabled" => true
        }

        job = if agent_name, do: Map.put(job, "agent_name", agent_name), else: job
        job = if timeout_ms, do: Map.put(job, "timeout_ms", timeout_ms), else: job

        case Scheduler.add_job(job) do
          {:ok, created} ->
            body = Jason.encode!(%{status: "created", task: format_task(created)})
            conn |> put_resp_content_type("application/json") |> send_resp(201, body)

          {:error, reason} ->
            json_error(conn, 422, "validation_error", to_string(reason))
        end
      else
        _ -> json_error(conn, 400, "invalid_request", "Missing required field: name")
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── POST /:id/trigger — manual trigger (run now) ─────────────────

  post "/:id/trigger" do
    try do
      jobs = Scheduler.list_jobs()

      case Enum.find(jobs, &(&1["id"] == id)) do
        nil ->
          json_error(conn, 404, "not_found", "Task not found")

        task ->
          case HeartbeatExecutor.execute(task, :manual) do
            {:ok, run} ->
              body = Jason.encode!(%{status: "ok", run: format_run(run)})
              conn |> put_resp_content_type("application/json") |> send_resp(200, body)

            {:error, :locked} ->
              json_error(conn, 409, "locked", "Task is already running")

            {:error, :budget_exceeded} ->
              json_error(conn, 402, "budget_exceeded", "Budget limit exceeded")

            {_, run} when is_map(run) ->
              body = Jason.encode!(%{status: "failed", run: format_run(run)})
              conn |> put_resp_content_type("application/json") |> send_resp(200, body)

            {:error, reason} ->
              json_error(conn, 500, "execution_error", to_string(reason))
          end
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── PUT /:id/toggle — enable/disable ─────────────────────────────

  put "/:id/toggle" do
    try do
      enabled = conn.body_params["enabled"]

      enabled? =
        case enabled do
          true -> true
          false -> false
          "true" -> true
          "false" -> false
          _ -> nil
        end

      if is_nil(enabled?) do
        json_error(conn, 400, "invalid_request", "Missing required field: enabled")
      else
        case Scheduler.toggle_job(id, enabled?) do
          :ok ->
            body = Jason.encode!(%{status: "ok", enabled: enabled?})
            conn |> put_resp_content_type("application/json") |> send_resp(200, body)

          {:error, reason} ->
            json_error(conn, 404, "not_found", to_string(reason))
        end
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── GET /:id/runs/:run_id — single run detail ───────────────────

  get "/:id/runs/:run_id" do
    try do
      case HeartbeatExecutor.get_run(run_id) do
        nil ->
          json_error(conn, 404, "not_found", "Run not found")

        run ->
          body = Jason.encode!(%{status: "ok", run: format_run(run)})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── GET /:id/runs — run history ──────────────────────────────────

  get "/:id/runs" do
    try do
      {page, per_page} = pagination_params(conn)
      runs = HeartbeatExecutor.list_runs(id, page: page, per_page: per_page)

      body =
        Jason.encode!(%{
          status: "ok",
          runs: Enum.map(runs, &format_run/1),
          count: length(runs),
          page: page,
          per_page: per_page
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── PUT /:id — update task fields ───────────────────────────────

  put "/:id" do
    try do
      jobs = Scheduler.list_jobs()

      case Enum.find(jobs, &(&1["id"] == id)) do
        nil ->
          json_error(conn, 404, "not_found", "Task not found")

        existing ->
          case Scheduler.remove_job(id) do
            :ok ->
              updated_job = build_updated_job(id, conn.body_params, existing)

              case Scheduler.add_job(updated_job) do
                {:ok, result} ->
                  body = Jason.encode!(%{status: "ok", task: format_task(result)})
                  conn |> put_resp_content_type("application/json") |> send_resp(200, body)

                {:error, reason} ->
                  json_error(conn, 422, "validation_error", to_string(reason))
              end

            {:error, reason} ->
              json_error(conn, 500, "update_failed", to_string(reason))
          end
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── DELETE /:id — delete task ────────────────────────────────────

  delete "/:id" do
    try do
      case Scheduler.remove_job(id) do
        :ok ->
          body = Jason.encode!(%{status: "ok"})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:error, reason} ->
          json_error(conn, 404, "not_found", to_string(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    catch
      :exit, _ -> json_error(conn, 503, "scheduler_unavailable", "Scheduler is not running")
    end
  end

  # ── Catch-all ────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp format_task(task) do
    %{
      id: task["id"],
      name: task["name"],
      schedule: task["schedule"],
      type: task["type"],
      enabled: task["enabled"],
      agent_name: task["agent_name"],
      failure_count: task["failure_count"] || 0,
      circuit_open: task["circuit_open"] || false,
      next_run: format_datetime(CronPresets.next_run(task["schedule"])),
      description: CronPresets.describe(task["schedule"])
    }
  end

  defp format_run(run) do
    %{
      id: run.id,
      scheduled_task_id: run.scheduled_task_id,
      agent_name: run.agent_name,
      status: run.status,
      trigger_type: run.trigger_type,
      started_at: format_datetime(run.started_at),
      completed_at: format_datetime(run.completed_at),
      duration_ms: run.duration_ms,
      exit_code: run.exit_code,
      stdout: run.stdout,
      error_message: run.error_message,
      token_usage: run.token_usage
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp build_updated_job(id, updates, existing) do
    %{
      "id" => id,
      "name" => updates["name"] || existing["name"],
      "schedule" => updates["cron"] || updates["schedule"] || existing["schedule"],
      "type" => updates["type"] || existing["type"],
      "job" => updates["prompt"] || updates["job"] || existing["job"],
      "enabled" => Map.get(updates, "enabled", existing["enabled"]),
      "agent_name" => updates["agent_name"] || existing["agent_name"],
      "timeout_ms" => updates["timeout_ms"] || existing["timeout_ms"]
    }
  end
end
