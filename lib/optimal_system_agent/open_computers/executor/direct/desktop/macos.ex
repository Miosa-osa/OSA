defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS do
  @moduledoc """
  Manages a single `osa-screen-capture-darwin` helper process on macOS.

  The helper is a native Swift binary that:
    - Uses ScreenCaptureKit to capture the primary display.
    - Runs a minimal RFB server bound to 127.0.0.1 on an ephemeral port.
    - Announces the port by printing `PORT=<n>` to stdout (same contract as x11vnc.ex).
    - Injects mouse/keyboard input via CGEventCreate* + CGEventPost.

  Requires Screen Recording + Accessibility permissions in System Settings.

  Helper lookup order (first found wins):
    1. A hash-pinned override (`OSA_DESKTOP_HELPER_OVERRIDE` +
       `OSA_DESKTOP_HELPER_SHA256`)
    2. `<priv>/helpers/osa-screen-capture-darwin`  (bundled in release)

  `~/.osa/helpers/` is deliberately NOT searched: it is user-writable, and
  this binary is executed on every desktop capture. See `Desktop.HelperPath`.

  If no trusted binary exists, returns `{:error, {:missing_helper, message}}` —
  callers should surface the install hint to the user.

  See docs/macos-desktop.md for architecture details and ship status.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperPath

  @helper_name "osa-screen-capture-darwin"
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
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    catch_exit(fn -> Port.close(port) end)
    :ok
  end

  @doc """
  Controller-compatible adapter API.

  Returns `{:ok, %{port_ref: port, os_pid: pid, vnc_port: port_number}}`. The
  RFB port travels with the handle — the caller must connect to the port this
  helper reported, never a fixed one.
  """
  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(_opts \\ %{}) do
    case spawn() do
      {:ok, %__MODULE__{port: port, os_pid: os_pid, vnc_port: vnc_port}} ->
        {:ok, %{port_ref: port, os_pid: os_pid, vnc_port: vnc_port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop the helper by Port reference (as returned by `start/1`)."
  @spec stop(port() | map()) :: :ok
  def stop(%{port_ref: port_ref}), do: stop(port_ref)

  def stop(port_ref) when is_port(port_ref) do
    case Port.info(port_ref, :os_pid) do
      {:os_pid, os_pid} -> kill(%__MODULE__{port: port_ref, os_pid: os_pid})
      _ -> catch_exit(fn -> Port.close(port_ref) end)
    end

    :ok
  end

  def stop(_), do: :ok

  # ── Private ──────────────────────────────────────────────────────────

  # The bundled binary is preferred over a user-writable override: anything
  # running as the user can drop a file in `~/.osa/helpers` and it would
  # otherwise be executed on every desktop capture. An override is opt-in and
  # must match a pinned hash — see `Desktop.HelperPath`.
  defp find_helper do
    priv_path = Path.join(:code.priv_dir(:optimal_system_agent), "helpers/#{@helper_name}")
    user_path = Path.expand("~/.osa/helpers/#{@helper_name}")

    HelperPath.resolve(@helper_name, priv_path, user_path, "docs/macos-desktop.md")
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
                  Logger.debug("[MacOS] helper announced RFB port #{vnc_port}")
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
