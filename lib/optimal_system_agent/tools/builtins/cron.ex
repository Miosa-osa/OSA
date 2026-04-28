defmodule OptimalSystemAgent.Tools.Builtins.Cron do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Scheduler

  @impl true
  def name, do: "cron"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Manage scheduled recurring tasks.\n\n" <>
      "Actions:\n" <>
      "- `create` — schedule a new recurring task with a cron expression\n" <>
      "- `list` — list all scheduled tasks\n" <>
      "- `delete` — remove a scheduled task by ID\n" <>
      "- `trigger` — manually trigger a scheduled task immediately\n\n" <>
      "Cron expressions: \"0 */6 * * *\" (every 6h), \"*/30 * * * *\" (every 30m),\n" <>
      "or presets: \"hourly\", \"daily\", \"weekly\""
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["create", "list", "delete", "trigger"],
          "description" => "Action to perform"
        },
        "task" => %{
          "type" => "string",
          "description" => "Task description (for create)"
        },
        "schedule" => %{
          "type" => "string",
          "description" => "Cron expression or preset name (for create)"
        },
        "job_id" => %{
          "type" => "string",
          "description" => "Job ID (for delete/trigger)"
        }
      }
    }
  end

  @impl true
  def execute(%{"action" => "create"} = args) do
    task = Map.get(args, "task", "")
    schedule = Map.get(args, "schedule", "hourly")

    if String.trim(task) == "" do
      {:error, "Missing required parameter: task"}
    else
      case Scheduler.create_job(%{task: task, schedule: schedule}) do
        {:ok, job} ->
          {:ok,
           "Scheduled job created:\n- ID: #{job.id}\n- Schedule: #{schedule}\n- Task: #{task}"}

        {:error, reason} ->
          {:error, "Failed to create job: #{inspect(reason)}"}
      end
    end
  rescue
    e -> {:error, "Scheduler error: #{Exception.message(e)}"}
  end

  def execute(%{"action" => "list"}) do
    case Scheduler.list_jobs() do
      jobs when is_list(jobs) and length(jobs) > 0 ->
        formatted =
          Enum.map(jobs, fn job ->
            status = Map.get(job, :status, "active")
            "- #{job.id}: #{job.task} (#{job.schedule}) [#{status}]"
          end)
          |> Enum.join("\n")

        {:ok, "Scheduled jobs:\n#{formatted}"}

      _ ->
        {:ok, "No scheduled jobs."}
    end
  rescue
    _ -> {:ok, "No scheduled jobs (scheduler not available)."}
  end

  def execute(%{"action" => "delete", "job_id" => id}) do
    case Scheduler.delete_job(id) do
      :ok -> {:ok, "Job #{id} deleted."}
      {:error, reason} -> {:error, "Failed to delete job: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Delete error: #{Exception.message(e)}"}
  end

  def execute(%{"action" => "trigger", "job_id" => id}) do
    case Scheduler.trigger_job(id) do
      :ok -> {:ok, "Job #{id} triggered."}
      {:error, reason} -> {:error, "Failed to trigger: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Trigger error: #{Exception.message(e)}"}
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Use create, list, delete, or trigger."}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}
end
