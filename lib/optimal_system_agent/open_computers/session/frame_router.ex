defmodule OptimalSystemAgent.OpenComputers.Session.FrameRouter do
  @moduledoc """
  Routes decoded frames from the control plane to the appropriate handler.

  Called by the WebSocket session process for every inbound decoded frame.

  ## Frame dispatch table

  | Frame                | Handler                                       |
  |----------------------|-----------------------------------------------|
  | `:exec_request`      | `Executor.Direct.Exec.start_job/2`            |
  | `:exec_cancel`       | `Executor.Direct.Exec.cancel_job/2`           |
  | `:job` (VM-dispatch) | logged, not yet implemented in OSA            |
  | `:heartbeat`         | forwarded to heartbeat responder              |
  | `{:hello_ok, ...}`   | logged (handshake confirmed)                  |
  | other                | logged as unhandled                           |

  Outgoing frames (chunks, results, errors) are produced by the executor
  task and sent directly to the session process as `{:exec_chunk, ...}`,
  `{:exec_result, ...}`, `{:exec_error, ...}` messages. The session process
  is responsible for encoding and forwarding them over the WebSocket.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Exec

  @doc """
  Route a decoded frame. `exec_pid` is the `Exec` GenServer for this session.
  `session_pid` is the WebSocket session process (receives result frames).

  Returns `:ok` always — errors in handlers are logged but not raised.
  """
  @spec route(term(), pid(), pid()) :: :ok
  def route({:exec_request, payload}, exec_pid, _session_pid) do
    Logger.debug("[OC.FrameRouter] exec_request job_id=#{inspect(payload[:job_id])}")

    case Exec.start_job(exec_pid, payload) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[OC.FrameRouter] exec start_job failed: #{inspect(reason)}")
    end

    :ok
  end

  def route({:exec_cancel, %{job_id: job_id}}, exec_pid, _session_pid) do
    Logger.debug("[OC.FrameRouter] exec_cancel job_id=#{job_id}")
    Exec.cancel_job(exec_pid, job_id)
    :ok
  end

  def route({:exec_cancel, payload}, exec_pid, _session_pid) when is_map(payload) do
    job_id = Map.get(payload, :job_id) || Map.get(payload, "job_id")
    if job_id, do: Exec.cancel_job(exec_pid, job_id)
    :ok
  end

  def route({:hello_ok, payload}, _exec_pid, _session_pid) do
    Logger.info("[OC.FrameRouter] hello_ok host_id=#{inspect(Map.get(payload, :host_id))}")
    :ok
  end

  def route({:heartbeat, _payload}, _exec_pid, _session_pid) do
    # Heartbeats are handled at the transport layer (WebSocket ping/pong).
    # Log at debug level only to avoid noise.
    Logger.debug("[OC.FrameRouter] heartbeat received")
    :ok
  end

  def route({:job, payload}, _exec_pid, _session_pid) do
    Logger.warning("[OC.FrameRouter] received VM-dispatch job #{inspect(Map.get(payload, :id))} — not implemented in OSA yet")
    :ok
  end

  def route(frame, _exec_pid, _session_pid) do
    Logger.debug("[OC.FrameRouter] unhandled frame: #{inspect(elem(frame, 0), limit: 5)}")
    :ok
  end
end
