defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows do
  @moduledoc """
  Spawns the native Windows ScreenShare helper and manages its lifecycle.

  The helper is a C# .NET 8 single-file executable (built from
  `native/windows/ScreenShare/`) that:
    1. Attempts Desktop Duplication via DXGI/D3D11 (Phase 2 — currently stubs out)
    2. Falls back to a solid-colour stub frame when capture is unavailable
    3. Serves raw RFB (VNC) frames on `127.0.0.1:<port>` (default 5900)

  The executable is bundled under `priv/windows/ScreenShare.exe` inside the
  OSA release. On Windows, Burrito extracts it to a temp directory before start.

  ## Configuration

      config :optimal_system_agent,
        windows_helper_path: "C:\\\\custom\\\\path\\\\ScreenShare.exe"

  Or set `OSA_WINDOWS_HELPER` at runtime.

  ## Permissions (Windows 10/11)

  Desktop Duplication does NOT require elevated permissions on Windows 10+.
  It does require the process to be running in the same session as the desktop
  (i.e., not running as a service or SYSTEM account). OSA runs as the logged-in
  user so this is satisfied automatically.

  ## Return values

  - `{:ok, port_ref}` — helper started; `port_ref` is a `Port` for the OS process
  - `{:error, :helper_not_installed}` — binary not found at `@helper_path`
  - `{:error, :failed_to_start}` — binary found but Port.open failed
  """

  require Logger

  @default_port 5900

  @compile_env_path Application.compile_env(
                      :optimal_system_agent,
                      :windows_helper_path,
                      nil
                    )

  @type start_opt :: {:port, pos_integer()} | {:display, non_neg_integer()} | {:stub, boolean()}
  @type stop_ref  :: port()

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Start the Windows ScreenShare helper.

  ## Options

  - `:port`    — TCP port for the VNC server (default: #{@default_port})
  - `:display` — display index to capture (default: 0)
  - `:stub`    — pass `true` to skip real capture and serve solid-colour frames
                 (Phase 1 default — real capture is Phase 2)

  ## Return

  - `{:ok, port_ref}` — helper running; monitor the returned `port_ref` for exits
  - `{:error, :helper_not_installed}` — binary missing (run `dotnet publish`)
  - `{:error, :failed_to_start}` — Port.open raised (not Windows, .NET missing, etc.)
  """
  @spec start([start_opt()]) :: {:ok, port()} | {:error, :helper_not_installed | :failed_to_start}
  def start(opts \\ []) do
    bin = helper_path()

    unless File.exists?(bin) do
      Logger.warning("[Desktop.Windows] helper binary not found at #{bin}. " <>
                     "Build it: cd native/windows/ScreenShare && dotnet publish -c Release -r win-x64")
      {:error, :helper_not_installed}
    else
      port_num = Keyword.get(opts, :port, @default_port)
      display  = Keyword.get(opts, :display, 0)
      stub?    = Keyword.get(opts, :stub, false)

      args =
        ["--port", to_string(port_num), "--display", to_string(display)] ++
          if(stub?, do: ["--stub"], else: [])

      Logger.info("[Desktop.Windows] starting helper: #{bin} #{Enum.join(args, " ")}")

      try do
        port_ref =
          Port.open(
            {:spawn_executable, bin},
            [
              :binary,
              :use_stdio,
              :stderr_to_stdout,
              {:args, args},
              {:packet, 0}
            ]
          )

        Logger.info("[Desktop.Windows] helper started port_ref=#{inspect(port_ref)}")
        {:ok, port_ref}
      rescue
        err ->
          Logger.error("[Desktop.Windows] failed to open Port: #{inspect(err)}")
          {:error, :failed_to_start}
      end
    end
  end

  @doc """
  Stop the Windows ScreenShare helper.

  Sends `taskkill` to terminate the process, then closes the Port.
  Safe to call with `nil` (no-op).
  """
  @spec stop(port() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(port_ref) when is_port(port_ref) do
    try do
      os_pid = Port.info(port_ref)[:os_pid]

      if os_pid do
        # taskkill is the Windows equivalent of SIGTERM
        System.cmd("taskkill", ["/PID", to_string(os_pid), "/F"],
          stderr_to_stdout: true
        )
      end
    rescue
      _ -> :ok
    end

    try do
      Port.close(port_ref)
    rescue
      _ -> :ok
    end

    :ok
  end

  @doc """
  Returns `true` when the helper executable is present on disk.
  """
  @spec available?() :: boolean()
  def available?, do: File.exists?(helper_path())

  @doc """
  Path to the bundled ScreenShare.exe.

  Resolution order:
  1. `OSA_WINDOWS_HELPER` environment variable
  2. `config :optimal_system_agent, windows_helper_path: "..."` compile-time value
  3. `priv/windows/ScreenShare.exe` relative to the OTP application's priv dir
  """
  @spec helper_path() :: String.t()
  def helper_path do
    System.get_env("OSA_WINDOWS_HELPER") ||
      @compile_env_path ||
      default_priv_path()
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp default_priv_path do
    priv = :code.priv_dir(:optimal_system_agent) |> to_string()
    Path.join([priv, "windows", "ScreenShare.exe"])
  end
end
