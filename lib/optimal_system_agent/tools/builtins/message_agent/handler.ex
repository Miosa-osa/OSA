defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent.Handler do
  @moduledoc """
  Validation and execution logic for `message_agent`.

  Stages:
    * `validate/2`           — confirm action is present and a known value;
                               check required fields per action
    * `check_permissions/2`  — always allow
    * `execute/2`             — dispatch to `OptimalSystemAgent.Team` message callbacks
  """

  alias OptimalSystemAgent.Team
  alias OptimalSystemAgent.Tools.Builtins.MessageAgent.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    cond do
      action not in Constants.valid_actions() ->
        valid = Enum.join(Constants.valid_actions(), ", ")
        {:error, "Unknown action '#{action}'. Valid actions: #{valid}", -32_602}

      action == "send" and not (Map.has_key?(input, "to") and Map.has_key?(input, "message")) ->
        {:error, "send action requires 'to' and 'message' parameters", -32_602}

      action == "broadcast" and not Map.has_key?(input, "message") ->
        {:error, "broadcast action requires 'message' parameter", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "send", "to" => to, "message" => message} = args, ctx) do
    team_id = team_id(args, ctx)
    from = agent_id(args, ctx)
    Team.send_message(team_id, from, to, message)
    # Best-effort: surface it to the human on the recipient's SESSION topic
    # (shared contract %{type: :agent_message, from, text}) if the target maps to
    # a running session. Team mailbox delivery is unchanged.
    surface_agent_message(to, from, message)
    {:ok, "Message sent to #{to}."}
  end

  def execute(%{"action" => "read"} = args, ctx) do
    team_id = team_id(args, ctx)
    agent_id = agent_id(args, ctx)
    messages = Team.read_messages(team_id, agent_id)

    if messages == [] do
      {:ok, "No messages in your inbox."}
    else
      lines =
        Enum.map_join(messages, "\n", fn msg ->
          "**#{msg.from}** (#{DateTime.to_iso8601(msg.timestamp)}): #{msg.content}"
        end)

      {:ok, "## Messages (#{length(messages)})\n\n#{lines}"}
    end
  end

  def execute(%{"action" => "broadcast", "message" => message} = args, ctx) do
    team_id = team_id(args, ctx)
    from = agent_id(args, ctx)
    Team.broadcast_message(team_id, from, message)
    {:ok, "Message broadcast to all teammates."}
  end

  def execute(%{"action" => action}, _ctx) do
    {:ok,
     "Action '#{action}' requires additional parameters. " <>
       "Valid actions: #{Enum.join(Constants.valid_actions(), ", ")}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp surface_agent_message(to, from, message) do
    target = to |> to_string() |> String.trim_leading("@")

    resolved =
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, target) do
        [{_pid, _}] ->
          target

        [] ->
          try do
            OptimalSystemAgent.SessionRegistry
            |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
            |> Enum.find(&String.contains?(&1, target))
          rescue
            _ -> nil
          end
      end

    if resolved do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{resolved}",
        {:osa_event,
         %{
           type: :agent_message,
           session_id: resolved,
           from: from |> to_string() |> String.split(":") |> List.last(),
           text: message,
           timestamp: DateTime.utc_now()
         }}
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp team_id(args, _ctx), do: Map.get(args, "team_id", "default")

  defp agent_id(args, ctx) do
    Map.get(args, "__session_id__") ||
      (ctx && Map.get(ctx, :session_id)) ||
      "unknown"
  end
end
