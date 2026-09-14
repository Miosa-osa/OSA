defmodule OptimalSystemAgent.OpenComputers.Session.FrameRouter do
  @moduledoc """
  Inbound frame dispatch for the OSA-side MIOSA session.

  Routes decoded terms to the appropriate handler. Returns a list of
  actions for the Session GenServer to apply.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{Controller, SessionGrant}

  @type action ::
          :noop
          | {:send, term()}
          | {:start_heartbeat, pos_integer()}
          | :reconnect
          | {:close, term(), term()}

  @spec handle(term(), map()) :: {[action()], map()}
  def handle({:hello_ok, info}, state) do
    Logger.info("[OpenComputers.Session] hello_ok host_id=#{inspect(info[:host_id])}")
    heartbeat_ms = Map.get(info, :heartbeat_ms, 30_000)

    {[{:start_heartbeat, heartbeat_ms}],
     Map.merge(state, %{
       phase: :active,
       host_id: info[:host_id],
       owner_tenant_id: info[:owner_tenant_id]
     })}
  end

  def handle({:ping, seq}, state), do: {[{:send, {:pong, seq}}], state}

  def handle({:close, code, reason}, state) do
    {[{:close, code, reason}], state}
  end

  def handle({:job, job}, state) do
    Logger.info("[OpenComputers.Session] job id=#{inspect(job[:id])} kind=#{inspect(job[:kind])}")

    session_pid = self()
    reply = fn frame -> send(session_pid, {:executor_frame, frame}) end

    {context, state} =
      if job[:kind] in [:stream_native_desktop, "stream_native_desktop"],
        do: SessionGrant.consume(job, state),
        else: {[], state}

    case Executor.dispatch(job, reply, context) do
      :ok -> {[{:send, {:job_accept, job.id, 0}}], state}
      {:error, _reason} -> {[], state}
    end
  end

  def handle({:desktop_session_grant, grant}, state) when is_map(grant),
    do: {[], SessionGrant.accept(grant, state)}

  def handle({:desktop_start_request, payload} = frame, %{phase: :active} = state) do
    {context, state} = SessionGrant.consume(payload, state)
    Controller.handle_frame(frame, context)
    {[], state}
  end

  def handle({:desktop_stop, %{session_id: id}} = frame, %{phase: :active} = state) do
    Controller.handle_frame(frame)
    {[], SessionGrant.revoke(state, id)}
  end

  def handle({:desktop_data, _} = frame, %{phase: :active} = state) do
    Controller.handle_frame(frame)
    {[], state}
  end

  def handle({:grant_renewed, %{new_token: new_token} = info}, state) do
    Logger.info(
      "[OpenComputers.Session] grant renewed old_jti=#{inspect(info[:old_jti])} new_jti=#{inspect(info[:new_jti])}"
    )

    {[], Map.put(state, :grant_token, new_token)}
  end

  def handle(other, state) do
    Logger.debug("[OpenComputers.Session] unhandled frame #{inspect(other)}")
    {[], state}
  end
end
