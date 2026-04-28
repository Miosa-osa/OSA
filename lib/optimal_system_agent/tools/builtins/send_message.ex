defmodule OptimalSystemAgent.Tools.Builtins.SendMessage do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def name, do: "send_message"

  @impl true
  def description do
    "Send a message to another running agent by name or session ID. " <>
      "The target agent will receive the message injected into its context " <>
      "on the next reasoning iteration. Use for inter-agent collaboration."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["to", "message"],
      "properties" => %{
        "to" => %{
          "type" => "string",
          "description" => "Target agent name or session ID"
        },
        "message" => %{
          "type" => "string",
          "description" => "Message content to send to the target agent"
        }
      }
    }
  end

  @impl true
  def execute(%{"to" => to, "message" => message} = args) do
    sender_id = Map.get(args, "__session_id__", "unknown")

    # Try to resolve the target — check SessionRegistry first, then match by role name
    target_id = resolve_target(to)

    if target_id do
      # Deliver via PubSub — the target agent's react_loop checks for pending messages
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:agent:#{target_id}",
        {:agent_message,
         %{
           from: sender_id,
           to: target_id,
           content: message,
           timestamp: DateTime.utc_now()
         }}
      )

      # Also store in ETS for agents that aren't actively listening yet
      store_pending_message(target_id, sender_id, message)

      {:ok, "Message sent to #{to} (#{target_id})"}
    else
      {:ok, "Error: could not find agent '#{to}'. Use /agents to see running agents."}
    end
  end

  def execute(_), do: {:error, "Missing required parameters: to, message"}

  # ── Target Resolution ────────────────────────────────────────────────

  defp resolve_target(id_or_name) do
    # Direct session ID match
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id_or_name) do
      [{_pid, _}] ->
        id_or_name

      [] ->
        # Search by role name in registered sessions
        sessions =
          try do
            Registry.select(
              OptimalSystemAgent.SessionRegistry,
              [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]
            )
          rescue
            _ -> []
          end

        # Match sessions containing the role name
        match =
          Enum.find(sessions, fn {sid, _pid, _meta} ->
            String.contains?(sid, id_or_name)
          end)

        case match do
          {sid, _, _} -> sid
          nil -> nil
        end
    end
  end

  # ── Pending Message Storage (ETS) ────────────────────────────────────

  @pending_table :osa_agent_messages

  defp store_pending_message(target_id, sender_id, message) do
    try do
      # Ensure table exists
      try do
        :ets.new(@pending_table, [:bag, :public, :named_table])
      rescue
        ArgumentError -> @pending_table
      end

      :ets.insert(
        @pending_table,
        {target_id,
         %{
           from: sender_id,
           content: message,
           timestamp: System.system_time(:millisecond)
         }}
      )
    rescue
      _ -> :ok
    end
  end

  @doc "Retrieve and clear pending messages for an agent. Called by react_loop."
  def drain_pending_messages(agent_id) do
    try do
      messages = :ets.lookup(@pending_table, agent_id)
      :ets.delete(@pending_table, agent_id)
      Enum.map(messages, fn {_key, msg} -> msg end)
    rescue
      _ -> []
    end
  end
end
