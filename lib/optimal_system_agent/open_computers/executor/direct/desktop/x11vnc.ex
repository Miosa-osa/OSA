defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc do
  @moduledoc """
  Manages a local x11vnc process on Linux hosts.

  Starts x11vnc bound to 127.0.0.1:5900 and returns the pid.
  The VNC socket is opened by the caller (DesktopController) after start
  so we don't hold the TCP resource here.

  ## Configuration

  The binary path can be overridden in config or at call time (for tests):

      config :optimal_system_agent, :x11vnc_bin, "/usr/bin/x11vnc"

  ## Security

  x11vnc is launched with:
    * `-localhost`  — only accepts connections from 127.0.0.1
    * `-nopw`       — no password (tunnel provides auth)
    * `-display :0` — default display
    * `-shared`     — allow reconnects without killing the server
    * `-forever`    — keep running after a client disconnects

  If x11vnc is not installed, `start/1` returns `{:error, :unsupported_platform}`.
  """

  require Logger

  @default_port 5900
  @default_display ":0"

  @type opts :: %{
          optional(:binary) => String.t(),
          optional(:port) => pos_integer(),
          optional(:display) => String.t()
        }

  @doc """
  Start x11vnc. Returns `{:ok, os_pid}` on success or `{:error, reason}`.

  `opts` keys:
    * `:binary`  — path to x11vnc (default from config or `/usr/bin/x11vnc`)
    * `:port`    — TCP port to listen on (default 5900)
    * `:display` — X display (default ":0")
  """
  @spec start(opts()) :: {:ok, pid()} | {:error, :unsupported_platform | :failed_to_start}
  def start(opts \\ %{}) do
    bin = opts[:binary] || configured_binary()
    port = opts[:port] || @default_port
    display = opts[:display] || @default_display

    unless File.exists?(bin) do
      Logger.warning("[X11vnc] binary not found at #{bin}")
      {:error, :unsupported_platform}
    else
      args = [
        "-display", display,
        "-localhost",
        "-nopw",
        "-rfbport", to_string(port),
        "-shared",
        "-forever",
        "-quiet"
      ]

      Logger.info("[X11vnc] starting: #{bin} #{Enum.join(args, " ")}")

      case :exec.run([bin | args], [:stdout, :stderr, :monitor]) do
        {:ok, _pid, os_pid} ->
          Logger.info("[X11vnc] started os_pid=#{os_pid} port=#{port}")
          {:ok, os_pid}

        {:error, reason} ->
          Logger.error("[X11vnc] failed to start: #{inspect(reason)}")
          {:error, :failed_to_start}
      end
    end
  rescue
    _ ->
      # :exec not available (non-Linux or missing dep) — fall back gracefully
      Logger.warning("[X11vnc] :exec library not available, trying Port")
      start_with_port(opts)
  end

  @doc "Stop x11vnc by its OS pid."
  @spec stop(integer() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(os_pid) when is_integer(os_pid) do
    try do
      :exec.stop(os_pid)
    rescue
      _ ->
        System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp start_with_port(opts) do
    bin = opts[:binary] || configured_binary()
    port = opts[:port] || @default_port
    display = opts[:display] || @default_display

    unless File.exists?(bin) do
      {:error, :unsupported_platform}
    else
      args = ["-display", display, "-localhost", "-nopw", "-rfbport", to_string(port), "-shared", "-forever", "-quiet"]
      port_ref = Port.open({:spawn_executable, bin}, [:binary, args: args])
      os_pid = Port.info(port_ref)[:os_pid]
      Logger.info("[X11vnc] started via Port os_pid=#{os_pid}")
      {:ok, os_pid}
    end
  end

  defp configured_binary do
    Application.get_env(:optimal_system_agent, :x11vnc_bin, "/usr/bin/x11vnc")
  end
end
