defmodule OptimalSystemAgent.Agent.Scheduler.Persistence do
  @moduledoc """
  Disk I/O and validation for CRONS.json and TRIGGERS.json.

  All writes are atomic (tmp file + rename) to prevent corruption.
  """
  require Logger
  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.System.JsonStore

  defp config_dir,
    do: Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()

  @doc "Path to the CRONS.json file."
  def crons_path, do: Path.expand(Path.join(config_dir(), "CRONS.json"))

  @doc "Path to the TRIGGERS.json file."
  def triggers_path, do: Path.expand(Path.join(config_dir(), "TRIGGERS.json"))

  @doc "Load cron jobs from CRONS.json into state."
  def load_crons(state) do
    path = crons_path()

    if File.exists?(path) do
      case with {:ok, raw} <- File.read(path),
                {:ok, decoded} <- Jason.decode(raw),
                do: {:ok, decoded} do
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

  @doc "Load triggers from TRIGGERS.json into state."
  def load_triggers(state) do
    path = triggers_path()

    if File.exists?(path) do
      case with {:ok, raw} <- File.read(path),
                {:ok, decoded} <- Jason.decode(raw),
                do: {:ok, decoded} do
        {:ok, %{"triggers" => triggers}} when is_list(triggers) ->
          enabled = Enum.filter(triggers, &(&1["enabled"] == true))

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

  @doc """
  Atomically update CRONS.json. Takes the current state and an update function
  that transforms the jobs list. Returns `{:ok, updated_state}` or `{:error, reason}`.
  """
  def update_crons(state, update_fn) do
    path = crons_path()

    # A corrupt CRONS.json must NOT degrade to "no jobs". The old fallback was
    # `state.cron_jobs`, which is `[]` whenever boot-load hit a parse error
    # (load_crons/1 leaves state unchanged), so adding one job rewrote the file
    # with only that job and silently deleted every other cron the user had.
    with {:ok, current_jobs} <- JsonStore.read_list_for_write(path, "jobs"),
         updated_jobs = update_fn.(current_jobs),
         json = Jason.encode!(%{"jobs" => updated_jobs}, pretty: true),
         :ok <- AtomicFile.write(path, json) do
      state = load_crons(%{state | cron_jobs: []})
      {:ok, state}
    else
      {:error, :corrupt} -> {:error, JsonStore.corrupt_message("cron jobs", path)}
      {:error, reason} -> {:error, "Failed to write CRONS.json: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to update CRONS.json: #{Exception.message(e)}"}
  end

  @doc """
  Atomically update TRIGGERS.json. Takes the current state and an update function
  that transforms the triggers list. Returns `{:ok, updated_state}` or `{:error, reason}`.
  """
  def update_triggers(state, update_fn) do
    path = triggers_path()

    # Same wipe as update_crons/2 — see the note there.
    with {:ok, current_triggers} <- JsonStore.read_list_for_write(path, "triggers"),
         updated_triggers = update_fn.(current_triggers),
         json = Jason.encode!(%{"triggers" => updated_triggers}, pretty: true),
         :ok <- AtomicFile.write(path, json) do
      state = load_triggers(%{state | trigger_handlers: %{}, triggers_raw: []})
      {:ok, state}
    else
      {:error, :corrupt} -> {:error, JsonStore.corrupt_message("triggers", path)}
      {:error, reason} -> {:error, "Failed to write TRIGGERS.json: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to update TRIGGERS.json: #{Exception.message(e)}"}
  end

  @doc "Validate a cron job map before persisting."
  def validate_job(job) do
    alias OptimalSystemAgent.Agent.Scheduler.CronEngine

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
        case CronEngine.parse(job["schedule"]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Invalid cron schedule: #{reason}"}
        end
    end
  end

  @doc "Validate a trigger map before persisting."
  def validate_trigger(trigger) do
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
end
