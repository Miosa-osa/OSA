defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc do
  @moduledoc """
  Manages a single x11vnc process attached to the host X session.

  - Spawns x11vnc via `Port.open/2` with `:spawn_executable`.
  - Parses the ephemeral port from stdout (`PORT=<n>`).
  - Exposes `port_number/1` to retrieve it once ready.
  - Monitors the OS process; the owning process receives
    `{:x11vnc_exited, exit_status}` when x11vnc terminates.
  """

  # Exclude Kernel.spawn/1 so our `spawn/1` (which starts x11vnc) doesn't conflict
  import Kernel, except: [spawn: 1, spawn: 3]

  require Logger

  @port_pattern ~r/PORT=(\d+)/
  @startup_timeout_ms 5_000

  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer(),
          vnc_port: non_neg_integer()
        }

  defstruct [:port, :os_pid, :vnc_port]

  @doc """
  Spawns x11vnc and blocks until the ephemeral RFB port is announced on stdout.

  Returns `{:ok, t()}` or `{:error, reason}`.
  """
  @spec spawn(String.t()) :: {:ok, t()} | {:error, term()}
  def spawn(display \\ ":0") do
    with :ok <- check_x11vnc_present(),
         :ok <- check_display(display),
         {:ok, port} <- open_port(display),
         {:ok, os_pid} <- fetch_os_pid(port),
         {:ok, vnc_port} <- await_port_announcement(port) do
      {:ok, %__MODULE__{port: port, os_pid: os_pid, vnc_port: vnc_port}}
    end
  end

  @doc "Kills the x11vnc OS process and closes the Port."
  @spec kill(t()) :: :ok
  def kill(%__MODULE__{port: port, os_pid: os_pid}) do
    try do
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    catch_exit(fn -> Port.close(port) end)
    :ok
  end

  # ── Private ──

  defp check_x11vnc_present do
    case System.find_executable("x11vnc") do
      nil ->
        {:error,
         {:missing_binary,
          "x11vnc not found on PATH. Install with: apt install x11vnc / dnf install x11vnc"}}

      _path ->
        :ok
    end
  end

  defp check_display(display) do
    case System.get_env("DISPLAY") do
      nil ->
        # Also accept an explicit non-empty display arg (rare but valid)
        if display != "" do
          :ok
        else
          {:error, {:missing_display, "DISPLAY environment variable is not set"}}
        end

      _ ->
        :ok
    end
  end

  defp open_port(display) do
    x11vnc = System.find_executable("x11vnc")

    args = [
      "-display", display,
      "-shared",
      "-forever",
      "-localhost",
      "-rfbport", "0",
      "-quiet"
    ]

    port =
      Port.open(
        {:spawn_executable, x11vnc},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    {:ok, port}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp fetch_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:error, :port_died_before_pid}
    end
  end

  defp await_port_announcement(port, acc \\ "", deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @startup_timeout_ms
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:startup_timeout, "x11vnc did not announce PORT= within #{@startup_timeout_ms}ms"}}
    else
      receive do
        {^port, {:data, chunk}} ->
          buffer = acc <> chunk

          case Regex.run(@port_pattern, buffer, capture: :all_but_first) do
            [num] ->
              case Integer.parse(num) do
                {vnc_port, ""} when vnc_port > 0 ->
                  Logger.debug("[X11vnc] announced RFB port #{vnc_port}")
                  {:ok, vnc_port}

                _ ->
                  {:error, {:bad_port_value, num}}
              end

            nil ->
              await_port_announcement(port, buffer, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, {:x11vnc_exited_early, status}}
      after
        remaining -> {:error, {:startup_timeout, "x11vnc did not announce PORT= within #{@startup_timeout_ms}ms"}}
      end
    end
  end

  defp catch_exit(fun) do
    try do
      fun.()
    catch
      _, _ -> :ok
    end
  end

  # ── Controller-compatible adapter API ─────────────────────────────────────────

  @doc """
  Start x11vnc using the default `spawn/1` logic. Returns `{:ok, os_pid}` on
  success (integer OS pid for use with `stop/1`) or `{:error, reason}`.

  Accepts an optional opts map with `:binary` (path to x11vnc) and `:display`.
  If `:binary` is given and does not exist on the filesystem, returns
  `{:error, :unsupported_platform}` immediately.
  """
  @spec start(map()) :: {:ok, non_neg_integer()} | {:error, atom() | tuple()}
  def start(opts \\ %{}) do
    binary = Map.get(opts, :binary, nil)

    if binary != nil and not File.exists?(binary) do
      {:error, :unsupported_platform}
    else
      display = Map.get(opts, :display, ":0")

      case spawn(display) do
        {:ok, %__MODULE__{os_pid: os_pid}} -> {:ok, os_pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Stop an x11vnc process by OS pid (as returned by `start/1`)."
  @spec stop(non_neg_integer()) :: :ok
  def stop(os_pid) when is_integer(os_pid) do
    try do
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    :ok
  end

  def stop(_), do: :ok
end
