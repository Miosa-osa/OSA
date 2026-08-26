defmodule OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Handler do
  @moduledoc """
  Validation, permission, and execution for `remote_trigger`.

  Delegates to `OptimalSystemAgent.Agent.Scheduler` which already exposes
  `add_trigger/1`, `remove_trigger/1`, `list_triggers/0`, and `fire_trigger/2`.
  """

  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    cond do
      action not in Constants.actions() ->
        {:error, "action must be one of: #{Enum.join(Constants.actions(), ", ")}", -32_602}

      action in ["fire", "remove"] and not is_binary(input["trigger_id"]) ->
        {:error, "#{action} requires trigger_id (string)", -32_602}

      action == "create" and not is_binary(input["type"]) ->
        {:error, "create requires type (string)", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "create"} = input, _ctx) do
    trigger_map = %{
      type: input["type"],
      job_id: input["job_id"],
      payload_schema: input["payload_schema"] || %{},
      enabled?: true
    }

    case Scheduler.add_trigger(trigger_map) do
      {:ok, trigger} ->
        {:ok, "Created trigger #{Map.get(trigger, :id, "?")} (#{input["type"]})"}

      {:error, reason} ->
        {:error, "Failed to create trigger: #{inspect(reason)}"}

      other ->
        {:ok, "Trigger created: #{inspect(other)}"}
    end
  end

  def execute(%{"action" => "list"}, _ctx) do
    triggers = Scheduler.list_triggers()

    if triggers == [] do
      {:ok, "No registered triggers"}
    else
      lines =
        triggers
        |> Enum.map(fn t ->
          id = Map.get(t, :id, "?")
          type = Map.get(t, :type, "?")
          job = Map.get(t, :job_id, "-")
          enabled = if Map.get(t, :enabled?, true), do: "enabled", else: "disabled"
          "#{id} | #{type} | job=#{job} | #{enabled}"
        end)
        |> Enum.join("\n")

      {:ok, lines}
    end
  end

  def execute(%{"action" => "remove", "trigger_id" => id}, _ctx) do
    case Scheduler.remove_trigger(id) do
      :ok -> {:ok, "Removed trigger #{id}"}
      {:ok, _} -> {:ok, "Removed trigger #{id}"}
      {:error, reason} -> {:error, "Failed to remove #{id}: #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => "fire", "trigger_id" => id} = input, _ctx) do
    payload = input["payload"] || %{}

    case Scheduler.fire_trigger(id, payload) do
      :ok -> {:ok, "Fired trigger #{id}"}
      {:ok, _} -> {:ok, "Fired trigger #{id}"}
      {:error, reason} -> {:error, "Failed to fire #{id}: #{inspect(reason)}"}
    end
  end

  def execute(_, _ctx), do: {:error, "Unsupported action"}
end
