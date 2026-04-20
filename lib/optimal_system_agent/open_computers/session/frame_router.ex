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

  alias OptimalSystemAgent.OpenComputers.Executor.Config
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Exec
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Fs

  @fs_request_tags [
    :fs_list_request,
    :fs_stat_request,
    :fs_read_request,
    :fs_write_request,
    :fs_delete_request,
    :fs_mkdir_request
  ]

  @doc """
  Route a decoded frame. `exec_pid` is the `Exec` GenServer for this session.
  `session_pid` is the WebSocket session process (receives result frames).

  Returns `:ok` always — errors in handlers are logged but not raised.
  """
  @spec route(term(), pid(), pid()) :: :ok
  def route({tag, payload}, _exec_pid, session_pid) when tag in @fs_request_tags do
    req_id = Map.get(payload, :req_id) || Map.get(payload, "req_id") || "unknown"

    if Config.fs_enabled?() do
      dispatch_fs(tag, req_id, payload, session_pid)
    else
      send(session_pid, {:fs_error, %{req_id: req_id, reason: :unknown}})
    end

    :ok
  end

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

  # ── Private ──────────────────────────────────────────────────────────────

  defp dispatch_fs(tag, req_id, payload, session_pid) do
    Task.start(fn ->
      start_ms = System.monotonic_time(:millisecond)

      response =
        try do
          case tag do
            :fs_list_request -> Fs.list(req_id, payload)
            :fs_stat_request -> Fs.stat(req_id, payload)
            :fs_read_request -> Fs.read(req_id, payload)
            :fs_write_request -> Fs.write(req_id, payload)
            :fs_delete_request -> Fs.delete(req_id, payload)
            :fs_mkdir_request -> Fs.mkdir(req_id, payload)
          end
        rescue
          e ->
            Logger.error("[OC.FrameRouter] fs op crashed: #{inspect(e)}")
            {:fs_error, %{req_id: req_id, reason: :unknown}}
        end

      elapsed_ms = System.monotonic_time(:millisecond) - start_ms
      op = tag |> to_string() |> String.replace("_request", "")
      emit_fs_telemetry(op, payload, elapsed_ms)

      send(session_pid, response)
    end)
  end

  defp emit_fs_telemetry(op, payload, elapsed_ms) do
    path = Map.get(payload, :path) || Map.get(payload, "path") || ""

    path_hash =
      :crypto.hash(:sha256, path)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    bytes =
      case Map.get(payload, :data) || Map.get(payload, "data") do
        data when is_binary(data) -> byte_size(data)
        _ -> 0
      end

    :telemetry.execute(
      [:open_computers, :fs, :request],
      %{bytes: bytes, duration_ms: elapsed_ms},
      %{op: op, path_hash: path_hash}
    )
  end
end
