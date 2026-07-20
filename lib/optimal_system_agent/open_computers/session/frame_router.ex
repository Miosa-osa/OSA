defmodule OptimalSystemAgent.OpenComputers.Session.FrameRouter do
  @moduledoc """
  Inbound frame dispatch for the OSA-side MIOSA session.

  Routes decoded terms to the appropriate handler. Returns a list of
  actions for the Session GenServer to apply.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor

  @type action ::
          :noop
          | {:send, term()}
          | {:start_heartbeat, pos_integer()}
          | :reconnect

  @spec handle(term(), map()) :: {[action()], map()}
  def handle({:hello_ok, info}, state) do
    Logger.info("[OpenComputers.Session] hello_ok host_id=#{inspect(info[:host_id])}")
    heartbeat_ms = Map.get(info, :heartbeat_ms, 30_000)
    {[{:start_heartbeat, heartbeat_ms}], Map.put(state, :phase, :active)}
  end

  def handle({:ping, seq}, state), do: {[{:send, {:pong, seq}}], state}

  def handle({:close, code, reason}, state) do
    Logger.info("[OpenComputers.Session] server close code=#{code} reason=#{reason}")
    {[:reconnect], state}
  end

  def handle({:job, job}, state) do
    Logger.info("[OpenComputers.Session] job id=#{inspect(job[:id])} kind=#{inspect(job[:kind])}")

    session_pid = self()
    reply = fn frame -> send(session_pid, {:executor_frame, frame}) end

    case Executor.dispatch(job, reply) do
      :ok -> {[{:send, {:job_accept, job.id, 0}}], state}
      {:error, _reason} -> {[], state}
    end
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
