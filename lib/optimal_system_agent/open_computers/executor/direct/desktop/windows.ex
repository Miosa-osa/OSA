defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows do
  @moduledoc """
  Manages a single `osa-screen-capture-windows.exe` helper process on Windows.

  The helper is a native C++/C# binary that uses the Desktop Duplication API
  (DXGI IDXGIOutputDuplication) to capture the primary display, runs a minimal
  RFB server on 127.0.0.1, and announces the port via `PORT=<n>` on stdout
  (same contract as x11vnc.ex / macos.ex). Input injection uses `SendInput`;
  see docs/windows-desktop.md for UAC / secure-desktop restrictions.

  Helper lookup order (first found wins):
    1. `%USERPROFILE%\\.osa\\helpers\\osa-screen-capture-windows.exe`
    2. `<priv>/helpers/osa-screen-capture-windows.exe`  (bundled in release)

  Returns `{:error, {:missing_helper, _}}` when neither path exists.
  See docs/windows-desktop.md for architecture details and ship status.
  """

  require Logger

  @helper_name "osa-screen-capture-windows.exe"
  @port_pattern ~r/PORT=(\d+)/
  @startup_timeout_ms 8_000

  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer(),
          vnc_port: non_neg_integer()
        }

  defstruct [:port, :os_pid, :vnc_port]

  @doc """
  Locates and spawns the native helper binary.

  Returns `{:ok, t()}` or `{:error, reason}`.
  """
  @spec spawn() :: {:ok, t()} | {:error, term()}
  def spawn do
    with {:ok, helper_path} <- find_helper(),
         {:ok, port} <- open_port(helper_path),
         {:ok, os_pid} <- fetch_os_pid(port),
         {:ok, vnc_port} <- await_port_announcement(port) do
      {:ok, %__MODULE__{port: port, os_pid: os_pid, vnc_port: vnc_port}}
    end
  end

  @doc "Terminates the helper OS process and closes the Port."
  @spec kill(t()) :: :ok
  def kill(%__MODULE__{port: port, os_pid: os_pid}) do
    try do
      System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    catch_exit(fn -> Port.close(port) end)
    Logger.debug("[Windows] desktop helper (pid #{os_pid}) terminated")
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp find_helper do
    user_path = build_user_path()
    priv_path = Path.join(:code.priv_dir(:optimal_system_agent), "helpers/#{@helper_name}")

    cond do
      not is_nil(user_path) and File.exists?(user_path) ->
        {:ok, user_path}

      File.exists?(priv_path) ->
        {:ok, priv_path}

      true ->
        {:error,
         {:missing_helper,
          "#{@helper_name} not found. " <>
            "Install via: osa opencomputers install-helper " <>
            "(see docs/windows-desktop.md)"}}
    end
  end

  # Resolves %USERPROFILE%\.osa\helpers\<name> — returns nil when the env var
  # is absent (e.g. running on Linux/macOS in tests).
  defp build_user_path do
    case System.get_env("USERPROFILE") do
      nil -> nil
      profile -> Path.join([profile, ".osa", "helpers", @helper_name])
    end
  end

  defp open_port(helper_path) do
    port =
      Port.open(
        {:spawn_executable, helper_path},
        [:binary, :exit_status, :stderr_to_stdout, args: []]
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
      {:error,
       {:startup_timeout,
        "#{@helper_name} did not announce PORT= within #{@startup_timeout_ms}ms"}}
    else
      receive do
        {^port, {:data, chunk}} ->
          buffer = acc <> chunk

          case Regex.run(@port_pattern, buffer, capture: :all_but_first) do
            [num] ->
              case Integer.parse(num) do
                {vnc_port, ""} when vnc_port > 0 ->
                  Logger.debug("[Windows] helper announced RFB port #{vnc_port}")
                  {:ok, vnc_port}

                _ ->
                  {:error, {:bad_port_value, num}}
              end

            nil ->
              await_port_announcement(port, buffer, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, {:helper_exited_early, status}}
      after
        remaining ->
          {:error,
           {:startup_timeout,
            "#{@helper_name} did not announce PORT= within #{@startup_timeout_ms}ms"}}
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
end
