defmodule OptimalSystemAgent.Channels.Session do
  @moduledoc "Shared session management for channel adapters."

  alias OptimalSystemAgent.Agent.Loop

  @doc "Ensure an agent loop exists for the given session. Creates one if needed."
  def ensure_loop(session_id, user_id, channel) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: channel}
        )
    end
  end
end
