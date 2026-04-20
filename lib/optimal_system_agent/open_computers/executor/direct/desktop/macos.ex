defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS do
  @moduledoc """
  Spawns the native macOS ScreenShare helper and manages its lifecycle.

  The helper is a Swift binary (built from `native/macos/ScreenShare/`) that:
    1. Requests ScreenCaptureKit permission via `SCShareableContent`
    2. Captures the primary display at 30 fps using `SCStream`
    3. Serves raw RFB (VNC) frames on `127.0.0.1:<port>` (default 5900)

  The binary is bundled under `priv/macos/ScreenShare` inside the OSA release.
  On first run it must be extracted from the Burrito bundle; this module handles
  the extraction path via `priv_dir(:optimal_system_agent)`.

  ## Configuration

      config :optimal_system_agent,
        macos_helper_path: "/custom/path/to/ScreenShare"

  Or set the `OSA_MACOS_HELPER` environment variable at runtime.

  ## Permissions (macOS TCC)

  The first call to `start/1` will trigger the system Screen Recording consent
  dialog via `SCShareableContent.current`. If the user denies permission, the
  helper falls back to a solid-colour stub frame (the pipeline still works, the
  client just sees a blue screen). Grant permission in:

      System Preferences → Privacy & Security → Screen Recording → OSA (or ScreenShare)

  ## Return values

  - `{:ok, port_ref}` — helper started; `port_ref` is a `Port` for the OS process
  - `{:error, :helper_not_installed}` — binary not found at `@helper_path`
  - `{:error, :failed_to_start}` — binary found but Port.open failed
  """

  require Logger

  @default_port 5900

  # Resolve at compile time so the path is embedded in the module but can be
  # overridden at runtime via config or env var.
  @compile_env_path Application.compile_env(
                      :optimal_system_agent,
                      :macos_helper_path,
                      nil
                    )

  @type start_opt :: {:port, pos_integer()} | {:display, non_neg_integer()} | {:stub, boolean()}
  @type stop_ref  :: port()

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Start the macOS ScreenShare helper.

  ## Options

  - `:port`    — TCP port for the VNC server (default: #{@default_port})
  - `:display` — display index to capture (default: 0)
  - `:stub`    — pass `true` to skip real capture and serve solid-colour frames
                 (useful for development/testing without Screen Recording permission)

  ## Return

  - `{:ok, port_ref}` — helper running; monitor the returned `port_ref` for exits
  - `{:error, :helper_not_installed}` — binary missing (run `make native.macos`)
  - `{:error, :failed_to_start}` — Port.open raised (permissions, arch mismatch, etc.)
  """
  @spec start([start_opt()]) :: {:ok, port()} | {:error, :helper_not_installed | :failed_to_start}
  def start(opts \\ []) do
    bin = helper_path()

    unless File.exists?(bin) do
      Logger.warning("[Desktop.MacOS] helper binary not found at #{bin}. " <>
                     "Build it: cd native/macos/ScreenShare && swift build -c release")
      {:error, :helper_not_installed}
    else
      port_num = Keyword.get(opts, :port, @default_port)
      display  = Keyword.get(opts, :display, 0)
      stub?    = Keyword.get(opts, :stub, false)

      args =
        ["--port", to_string(port_num), "--display", to_string(display)] ++
          if(stub?, do: ["--stub"], else: [])

      Logger.info("[Desktop.MacOS] starting helper: #{bin} #{Enum.join(args, " ")}")

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

        Logger.info("[Desktop.MacOS] helper started port_ref=#{inspect(port_ref)}")
        {:ok, port_ref}
      rescue
        err ->
          Logger.error("[Desktop.MacOS] failed to open Port: #{inspect(err)}")
          {:error, :failed_to_start}
      end
    end
  end

  @doc """
  Stop the ScreenShare helper.

  Sends SIGTERM to the OS process via the Port reference, then closes the Port.
  Safe to call with `nil` (no-op).
  """
  @spec stop(port() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(port_ref) when is_port(port_ref) do
    try do
      # Gentle: send SIGTERM so the binary can close the VNC socket cleanly
      os_pid = Port.info(port_ref)[:os_pid]
      if os_pid, do: System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
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
  Returns `true` when the helper binary is present on disk.

  Use this to guard `desktop_start_request` on macOS before attempting to start.
  """
  @spec available?() :: boolean()
  def available?, do: File.exists?(helper_path())

  @doc """
  Path to the bundled ScreenShare binary.

  Resolution order:
  1. `OSA_MACOS_HELPER` environment variable
  2. `config :optimal_system_agent, macos_helper_path: "..."` compile-time value
  3. `priv/macos/ScreenShare` relative to the OTP application's priv dir
  """
  @spec helper_path() :: String.t()
  def helper_path do
    System.get_env("OSA_MACOS_HELPER") ||
      @compile_env_path ||
      default_priv_path()
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp default_priv_path do
    # :code.priv_dir returns a charlist
    priv = :code.priv_dir(:optimal_system_agent) |> to_string()
    Path.join([priv, "macos", "ScreenShare"])
  end
end
