defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc do
  @moduledoc """
  Manages a single x11vnc process attached to the host X session.

  - Spawns x11vnc via `Port.open/2` with `:spawn_executable`.
  - Parses the ephemeral port from stdout (`PORT=<n>`).
  - Exposes `port_number/1` to retrieve it once ready.
  - Monitors the OS process; the owning process receives
    `{:x11vnc_exited, exit_status}` when x11vnc terminates.

  ## Access control

  The server shares the user's live screen and accepts remote input, so it is
  started with a per-session password (`-passwdfile rm:<0600 file>`), bound to
  loopback, limited to one viewer (no `-shared`) and exits when that viewer
  disconnects (no `-forever`). The password travels with the handle as
  `:secret` — whoever drives the RFB client needs it. See `build_args/2`.

  Authentication can be turned off with
  `config :optimal_system_agent, :desktop_vnc_auth, false`, which logs a
  warning; without it any local process can attach to the desktop.
  """

  # Exclude Kernel.spawn/1 so our `spawn/1` (which starts x11vnc) doesn't conflict
  import Kernel, except: [spawn: 1, spawn: 3]

  require Logger

  @port_pattern ~r/PORT=(\d+)/
  @startup_timeout_ms 5_000

  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer(),
          vnc_port: non_neg_integer(),
          secret: String.t() | nil
        }

  defstruct [:port, :os_pid, :vnc_port, :secret]

  @doc """
  Spawns x11vnc and blocks until the ephemeral RFB port is announced on stdout.

  Returns `{:ok, t()}` or `{:error, reason}`.
  """
  @spec spawn(String.t()) :: {:ok, t()} | {:error, term()}
  def spawn(display \\ ":0") do
    with :ok <- check_x11vnc_present(),
         :ok <- check_display(display),
         {:ok, auth} <- make_auth(),
         {:ok, port} <- open_port(display, auth),
         {:ok, os_pid} <- fetch_os_pid(port),
         {:ok, vnc_port} <- await_port_announcement(port) do
      {:ok,
       %__MODULE__{
         port: port,
         os_pid: os_pid,
         vnc_port: vnc_port,
         secret: auth && auth.secret
       }}
    end
  end

  @doc """
  Generate a per-session VNC password and write it to a `0600` file.

  Returns `{:ok, %{secret: secret, file: path}}`, or `{:ok, nil}` when
  authentication has been explicitly disabled by the operator.

  The secret is 8 characters because the classic RFB security type truncates
  the password to 8 bytes — a longer one would buy nothing. Combined with
  `-localhost` and a per-session lifetime, that is the strength the protocol
  allows; it exists to stop other local processes attaching, not to survive an
  offline attack.
  """
  @spec make_auth() :: {:ok, map() | nil} | {:error, term()}
  def make_auth do
    if auth_enabled?() do
      secret =
        6
        |> :crypto.strong_rand_bytes()
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 8)

      file =
        Path.join(
          System.tmp_dir!(),
          "osa-vnc-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}.pass"
        )

      # Create empty + chmod BEFORE writing the secret, so it is never
      # world-readable even briefly. x11vnc deletes the file after reading it
      # (`rm:` prefix).
      with :ok <- File.write(file, ""),
           :ok <- File.chmod(file, 0o600),
           :ok <- File.write(file, secret <> "\n") do
        {:ok, %{secret: secret, file: file}}
      else
        {:error, reason} -> {:error, {:vnc_secret_write_failed, reason}}
      end
    else
      Logger.warning(
        "[X11vnc] desktop_vnc_auth is disabled — the VNC server will accept any local " <>
          "connection with no password. Any process running as this user can drive the desktop."
      )

      {:ok, nil}
    end
  end

  defp auth_enabled? do
    Application.get_env(:optimal_system_agent, :desktop_vnc_auth, true) != false
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

  @doc """
  Build the x11vnc argv for `display`, authenticating with `secret`.

  Exposed so the argv can be asserted on without starting a server.

  Security-relevant choices:

    * `-passwdfile rm:<file>` — the password is read from a `0600` file that
      x11vnc deletes after reading, so it never appears in `ps` output. Without
      it x11vnc negotiates RFB security type None and ANY local process,
      including a sandboxed one, could attach and drive the desktop.
    * no `-shared` — one viewer at a time. `-shared` allowed unlimited
      simultaneous viewers of the user's live screen.
    * no `-forever` — x11vnc exits when the viewer disconnects rather than
      staying up serving the desktop after OSA is done with it.
    * `-localhost` + `-rfbport 0` — loopback only, kernel-assigned port.
  """
  @spec build_args(String.t(), map() | nil) :: [String.t()]
  def build_args(display, auth) do
    base = ["-display", display, "-localhost", "-rfbport", "0", "-quiet"]

    case auth do
      %{file: file} when is_binary(file) -> base ++ ["-passwdfile", "rm:" <> file]
      _ -> base
    end
  end

  defp open_port(display, auth) do
    x11vnc = System.find_executable("x11vnc")

    args = build_args(display, auth)

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
      {:error,
       {:startup_timeout, "x11vnc did not announce PORT= within #{@startup_timeout_ms}ms"}}
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
        remaining ->
          {:error,
           {:startup_timeout, "x11vnc did not announce PORT= within #{@startup_timeout_ms}ms"}}
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
  @spec start(map()) :: {:ok, map()} | {:error, atom() | tuple()}
  def start(opts \\ %{}) do
    binary = Map.get(opts, :binary, nil)

    if binary != nil and not File.exists?(binary) do
      {:error, :unsupported_platform}
    else
      display = Map.get(opts, :display, ":0")

      case spawn(display) do
        # The RFB port is ephemeral (`-rfbport 0`), so it MUST travel with the
        # handle. Returning only the os_pid is what left the controller
        # connecting to a hardcoded 5900 that this server never binds — i.e.
        # to whatever other desktop-sharing server happens to hold that port.
        {:ok, %__MODULE__{os_pid: os_pid, vnc_port: vnc_port, secret: secret}} ->
          {:ok, %{os_pid: os_pid, vnc_port: vnc_port, secret: secret}}

        {:error, reason} ->
          {:error, reason}
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
