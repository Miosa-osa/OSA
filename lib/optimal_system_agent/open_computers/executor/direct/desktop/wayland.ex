defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Wayland do
  @moduledoc """
  Consent-based Linux Wayland desktop helper adapter.

  Uses the logged-in user's XDG portal session, never XWayland root capture.
  The trusted helper announces an ephemeral loopback RFB port only after
  consent and a real PipeWire frame. See `docs/linux-wayland-desktop.md`.
  """

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperPath
  import Kernel, except: [spawn: 1]

  @helper "osa-screen-capture-wayland"
  @startup_timeout 125_000
  @max_output 16_384

  defstruct [:port, :os_pid, :vnc_port]

  @doc "Native executor interface, matching the other desktop helpers."
  def spawn(opts \\ %{}) do
    with {:ok, handle} <- start(opts) do
      {:ok, %__MODULE__{port: handle.port_ref, os_pid: handle.os_pid, vnc_port: handle.vnc_port}}
    end
  end

  def kill(%__MODULE__{port: port}), do: stop(port)

  def start(opts \\ %{}) do
    with :ok <- session_available(),
         {:ok, path} <- helper_path(),
         {:ok, port} <- open(path, opts) do
      case await_port(port, "", System.monotonic_time(:millisecond) + @startup_timeout) do
        {:ok, number} ->
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> {:ok, %{port_ref: port, os_pid: pid, vnc_port: number}}
            _ -> {:error, :helper_exited}
          end

        {:error, _} = error ->
          stop(port)
          error
      end
    end
  end

  def stop(%{port_ref: port}), do: stop(port)

  def stop(port) when is_port(port) do
    # Closing the owning Port closes stdin. The helper watches EOF even while
    # the portal consent dialog is open. Signal only the still-owned PID.
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  def stop(_), do: :ok

  defp session_available do
    if Enum.all?(["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"], fn name ->
         value = System.get_env(name)
         is_binary(value) and String.trim(value) != ""
       end),
       do: :ok,
       else: {:error, :wayland_session_unavailable}
  end

  defp helper_path do
    priv =
      case :code.priv_dir(:optimal_system_agent) do
        path when is_list(path) -> Path.join([List.to_string(path), "helpers", @helper])
        # Do not execute a relative priv/helpers path from an untrusted CWD.
        # An explicit hash-pinned override can still be used in source tests.
        _ -> ""
      end

    HelperPath.resolve(
      @helper,
      priv,
      nil,
      "docs/linux-wayland-desktop.md"
    )
  end

  defp open(path, opts) do
    args = [if(Map.get(opts, :allow_input) === true, do: "--allow-input", else: "--read-only")]

    {:ok,
     Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, args: args])}
  rescue
    _ -> {:error, :wayland_helper_spawn_failed}
  end

  defp await_port(port, buffer, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        data = buffer <> chunk

        cond do
          byte_size(data) > @max_output -> {:error, :startup_output_limit}
          true -> parse_announcement(port, data, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:wayland_helper_exited, status}}
    after
      remaining -> {:error, :wayland_consent_or_capture_timeout}
    end
  end

  defp parse_announcement(port, data, deadline) do
    case Regex.run(~r/(?:^|\n)PORT=([0-9]+)\r?\n/, data, capture: :all_but_first) do
      [number] ->
        case Integer.parse(number) do
          {n, ""} when n in 1..65_535 -> {:ok, n}
          _ -> {:error, :bad_port_value}
        end

      _ ->
        await_port(port, data, deadline)
    end
  end
end
