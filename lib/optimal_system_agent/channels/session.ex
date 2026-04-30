defmodule OptimalSystemAgent.Channels.Session do
  @moduledoc "Shared session management for channel adapters."

  @doc """
  Ensure an agent loop exists for the given session. Creates one if needed.

  Returns `:ok` on success. Handles `{:already_started, _}` races gracefully.
  Retries once on transient failures.
  """
  defdelegate ensure_loop(session_id, user_id, channel),
    to: OptimalSystemAgent.Runtime.SessionManager
end
