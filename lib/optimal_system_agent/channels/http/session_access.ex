defmodule OptimalSystemAgent.Channels.HTTP.SessionAccess do
  @moduledoc """
  Authorizes HTTP clients against the owner of a live agent session.

  Older local TUI releases minted a new `tui_*` user id whenever the backend's
  ephemeral JWT secret rotated. After a restart, the same person therefore
  appeared to be a different owner and could not resume their own session.
  Local OSA is a single-user, loopback-only service, so those legacy identities
  are compatible with the stable `local` identity. Remote and multi-user
  deployments still require an exact owner match.
  """

  alias OptimalSystemAgent.Channels.HTTP.Auth
  require Logger

  @spec authorize(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def authorize(session_id, requester) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] ->
        case authorize_owner(owner, requester, Auth.loopback_only?()) do
          :ok ->
            :ok

          {:error, :not_found} = error ->
            Logger.warning(
              "[API] Session ownership mismatch: session=#{session_id} " <>
                "owner=#{inspect(owner)} requester=#{inspect(requester)}"
            )

            error
        end

      _ ->
        :ok
    end
  end

  @doc false
  @spec authorize_owner(term(), term(), boolean()) :: :ok | {:error, :not_found}
  def authorize_owner(owner, requester, loopback_only?) do
    cond do
      requester == "anonymous" -> :ok
      owner == requester -> :ok
      legacy_local_owner?(owner, requester, loopback_only?) -> :ok
      true -> {:error, :not_found}
    end
  end

  # On a loopback-only daemon a `local` requester also owns any "anonymous"-owned
  # loop. A loop materialised under the `start_loop` "anonymous" default (a
  # cold-start race where the tracked meta is not written yet, or any future path
  # that skips the real owner) would otherwise mismatch `local` and 404, dropping
  # the session on the next stream (re)connect.
  defp legacy_local_owner?(owner, "local", true) when is_binary(owner),
    do: String.starts_with?(owner, "tui_") or owner == "anonymous"

  defp legacy_local_owner?(_, _, _), do: false
end
