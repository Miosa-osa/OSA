defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Bridge do
  @moduledoc """
  Glues the x11vnc TCP socket to the MIOSA relay WebSocket.

  Connects the TCP socket to the already-spawned x11vnc port, then
  enters `Relay.loop/3` in a linked Task so the parent GenServer receives
  `{:relay_done, reason}` when either side terminates.

  The bridge task is linked to the parent; if the parent exits first
  the Task dies automatically (and vice versa — the parent must handle
  `{:EXIT, task_pid, reason}` if it traps exits, or let it propagate).
  """

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Relay

  @doc """
  Opens the TCP connection to x11vnc, then spawns a linked Task that runs
  the bidirectional loop.

  Returns `{:ok, task}` so the caller can monitor it if needed, or
  `{:error, reason}` if the TCP connect fails.
  """
  @spec start(non_neg_integer(), Relay.ws_conn(), pid()) ::
          {:ok, Task.t()} | {:error, term()}
  def start(vnc_port, ws_conn, notify_pid) do
    case Relay.connect_tcp(vnc_port) do
      {:ok, tcp_sock} ->
        task =
          Task.async(fn ->
            Relay.loop(tcp_sock, ws_conn, notify_pid)
          end)

        {:ok, task}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
