defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent do
  @moduledoc """
  Send messages between agents in a team.

  Enables inter-agent communication via PubSub-backed mailbox.
  Agents can message specific teammates or broadcast to all.
  Messages are also stored in ETS for later retrieval.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Team

  @impl true
  def name, do: "message_agent"

  @impl true
  def description do
    "Send a message to another agent in your team, or read messages from teammates. " <>
      "Use to share findings, coordinate work, or request information from other agents."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["send", "read", "broadcast"],
          "description" =>
            "send: message one agent, read: check your inbox, broadcast: message all teammates"
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Team identifier."
        },
        "to" => %{
          "type" => "string",
          "description" => "Recipient agent session ID (for send action)."
        },
        "message" => %{
          "type" => "string",
          "description" => "Message content to send."
        }
      }
    }
  end

  @impl true
  def execute(%{"action" => "send", "to" => to, "message" => message} = args) do
    team_id = Map.get(args, "team_id", "default")
    from = Map.get(args, "__session_id__", "unknown")

    Team.send_message(team_id, from, to, message)
    {:ok, "Message sent to #{to}."}
  end

  def execute(%{"action" => "read"} = args) do
    team_id = Map.get(args, "team_id", "default")
    agent_id = Map.get(args, "__session_id__", "unknown")

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

  def execute(%{"action" => "broadcast", "message" => message} = args) do
    team_id = Map.get(args, "team_id", "default")
    from = Map.get(args, "__session_id__", "unknown")

    Team.broadcast_message(team_id, from, message)
    {:ok, "Message broadcast to all teammates."}
  end

  def execute(_), do: {:ok, "Invalid action. Use: send, read, broadcast"}
end
