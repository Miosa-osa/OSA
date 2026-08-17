defmodule OptimalSystemAgent.Agent.SessionHealth do
  @moduledoc """
  Read-only diagnostics for deciding whether a session is live, restorable, or degraded.

  Every field is independently derived so one damaged sidecar does not hide the
  rest of the recovery picture.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{ActiveSkills, SessionPersistence}
  alias OptimalSystemAgent.Runtime.SessionManager

  @spec snapshot(String.t()) :: map()
  def snapshot(session_id) when is_binary(session_id) do
    live = SessionManager.session_exists?(session_id)
    persistence = persistence_status(session_id)
    skills = skills_status(session_id)
    events = safe(fn -> SessionPersistence.event_count(session_id) end, 0)

    status =
      cond do
        live and persistence.status in [:ok, :absent] and skills.status == :ok -> :healthy
        live -> :degraded
        persistence.restorable -> :recoverable
        true -> :missing
      end

    %{
      session_id: session_id,
      status: status,
      live: live,
      persistence: persistence,
      active_skills: skills,
      durable_events: events,
      recovery_action: recovery_action(status)
    }
  end

  defp persistence_status(session_id) do
    exists = SessionPersistence.exists?(session_id)

    case SessionPersistence.load(session_id) do
      {:ok, messages} ->
        %{status: :ok, exists: exists, restorable: true, message_count: length(messages)}

      {:error, reason} ->
        if reason == :not_found do
          %{status: :absent, exists: exists, restorable: false, message_count: 0}
        else
          %{status: :error, exists: exists, restorable: false, error: bounded(reason)}
        end
    end
  rescue
    error -> %{status: :error, exists: false, restorable: false, error: bounded(error)}
  catch
    :exit, reason -> %{status: :error, exists: false, restorable: false, error: bounded(reason)}
  end

  defp skills_status(session_id) do
    case ActiveSkills.snapshots(session_id) do
      {:ok, entries} ->
        %{
          status: :ok,
          count: length(entries),
          names: Enum.map(entries, & &1.name),
          versioned: Enum.count(entries, &is_binary(&1.hash))
        }

      {:error, reason} ->
        %{status: :error, count: 0, names: [], versioned: 0, error: bounded(reason)}
    end
  end

  defp recovery_action(:healthy), do: "none"
  defp recovery_action(:recoverable), do: "resume_session"
  defp recovery_action(:degraded), do: "inspect_sidecars"
  defp recovery_action(:missing), do: "start_new_session"

  defp safe(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.error("[session_health] diagnostic failed: #{Exception.message(error)}")
      fallback
  catch
    kind, reason ->
      Logger.error("[session_health] diagnostic #{kind}: #{inspect(reason)}")
      fallback
  end

  defp bounded(reason),
    do: reason |> inspect(limit: 5, printable_limit: 160) |> String.slice(0, 200)
end
