defmodule OptimalSystemAgent.Tools.Builtins.Cron.Handler do
  @moduledoc """
  Validation, permission, and execution logic for the `cron` tool.

  Mirrors the three-stage pattern of FileRead.Handler:
    * `validate/2`          — type-check input shape, required fields per action
    * `check_permissions/2` — action-level access control
    * `execute/2`            — delegate to `OptimalSystemAgent.Agent.Scheduler`

  Scheduler public API mapping:
    | action  | Scheduler call             |
    |---------|----------------------------|
    | create  | Scheduler.add_job/1        |
    | list    | Scheduler.list_jobs/0      |
    | delete  | Scheduler.remove_job/1     |
    | trigger | Scheduler.run_job/1        |
  """

  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Tools.Builtins.Cron.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    if action in Constants.action_strings() do
      validate_action_params(action, input)
    else
      {:error,
       "Unknown action: #{inspect(action)}. Valid actions: #{Enum.join(Constants.action_strings(), ", ")}",
       -32_602}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"action" => "delete"} = input, ctx) do
    if ctx.permissions[:allow_destructive] == false do
      {:deny, "Access denied: cron delete requires destructive permission in this context"}
    else
      {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, any()} | {:error, String.t()}
  def execute(%{"action" => "create"} = input, _ctx) do
    task = input["task"] || ""
    schedule = input["schedule"] || "hourly"

    if String.trim(task) == "" do
      {:error, "Missing required parameter: task"}
    else
      job_map = %{
        "task" => task,
        "schedule" => schedule,
        "name" => String.slice(task, 0, 60),
        "type" => "agent",
        "enabled" => true
      }

      case Scheduler.add_job(job_map) do
        {:ok, job} ->
          {:ok, job}

        {:error, reason} ->
          {:error, "Failed to create cron job: #{inspect(reason)}"}
      end
    end
  rescue
    e -> {:error, "Scheduler error (create): #{Exception.message(e)}"}
  end

  def execute(%{"action" => "list"}, _ctx) do
    case Scheduler.list_jobs() do
      jobs when is_list(jobs) ->
        {:ok, jobs}

      other ->
        {:error, "Unexpected response from Scheduler.list_jobs/0: #{inspect(other)}"}
    end
  rescue
    _ -> {:ok, []}
  end

  def execute(%{"action" => "delete", "job_id" => job_id}, _ctx) when is_binary(job_id) do
    case Scheduler.remove_job(job_id) do
      :ok ->
        {:ok, %{"deleted" => true, "job_id" => job_id}}

      {:error, reason} ->
        {:error, "Failed to delete cron job #{inspect(job_id)}: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Scheduler error (delete): #{Exception.message(e)}"}
  end

  def execute(%{"action" => "trigger", "job_id" => job_id}, _ctx) when is_binary(job_id) do
    case Scheduler.run_job(job_id) do
      {:ok, result} ->
        {:ok, %{"triggered" => true, "job_id" => job_id, "result" => result}}

      {:error, reason} ->
        {:error, "Failed to trigger cron job #{inspect(job_id)}: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Scheduler error (trigger): #{Exception.message(e)}"}
  end

  def execute(%{"action" => action}, _ctx),
    do: {:error, "Unknown or incomplete action: #{inspect(action)}"}

  def execute(_, _ctx),
    do: {:error, "Missing required parameter: action"}

  # ── Private: per-action param validation ──────────────────────────────

  defp validate_action_params("create", %{"task" => task} = input) when is_binary(task) do
    {:ok, input}
  end

  defp validate_action_params("create", %{"task" => _}),
    do: {:error, "task must be a string", -32_602}

  defp validate_action_params("create", _),
    do: {:error, "Missing required parameter: task (required for create)", -32_602}

  defp validate_action_params("list", input), do: {:ok, input}

  defp validate_action_params("delete", %{"job_id" => id} = input) when is_binary(id),
    do: {:ok, input}

  defp validate_action_params("delete", %{"job_id" => _}),
    do: {:error, "job_id must be a string", -32_602}

  defp validate_action_params("delete", _),
    do: {:error, "Missing required parameter: job_id (required for delete)", -32_602}

  defp validate_action_params("trigger", %{"job_id" => id} = input) when is_binary(id),
    do: {:ok, input}

  defp validate_action_params("trigger", %{"job_id" => _}),
    do: {:error, "job_id must be a string", -32_602}

  defp validate_action_params("trigger", _),
    do: {:error, "Missing required parameter: job_id (required for trigger)", -32_602}
end
