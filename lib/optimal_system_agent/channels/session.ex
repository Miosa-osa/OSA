defmodule OptimalSystemAgent.Channels.Session do
  @moduledoc "Shared session management for channel adapters."

  alias OptimalSystemAgent.Agent.Loop
  require Logger

  @doc """
  Ensure an agent loop exists for the given session. Creates one if needed.

  Returns `:ok` on success. Handles `{:already_started, _}` races gracefully.
  Retries once on transient failures.
  """
  def ensure_loop(session_id, user_id, channel) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case start_loop(session_id, user_id, channel) do
          :ok ->
            :ok

          {:error, reason} ->
            # One retry — covers transient supervisor contention
            Logger.warning("[Session] Loop start failed (#{inspect(reason)}), retrying once")
            Process.sleep(50)

            case start_loop(session_id, user_id, channel) do
              :ok -> :ok
              {:error, reason2} -> {:error, reason2}
            end
        end
    end
  end

  defp start_loop(session_id, user_id, channel) do
    case DynamicSupervisor.start_child(
           OptimalSystemAgent.Channels.Supervisor,
           {Loop, session_id: session_id, user_id: to_string(user_id), channel: channel}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
