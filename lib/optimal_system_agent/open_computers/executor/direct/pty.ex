defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Pty do
  @moduledoc """
  PTY executor for OpenComputers terminal sessions.

  Spawns a real interactive shell with a PTY on the host machine.
  Each session is independently tracked in a GenServer state map.

  ## Shell selection

  The requested shell is validated against an allowlist from
  `~/.osa/open_computers.toml` (key `[pty] allowed_shells`).

  Default allowlist (Unix): `["/bin/bash", "/bin/sh"]`
  Default allowlist (Windows): `["powershell.exe", "cmd.exe"]` — Windows
  ConPTY support is not yet implemented; `pty_error :pty_unavailable` is
  returned for all Windows PTY requests. See TODO: issue #51.

  ## PTY spawning (Unix)

  Uses `:erlexec` (`{:erlexec, "~> 2.0"}`) for PTY spawning with
  `:pty`, `:stdin`, `:stdout`, `:monitor` options. Initial geometry is
  set at spawn time. Resize (`pty_resize`) is forwarded via
  `exec:send(os_pid, {:winsize, cols, rows})` if the erlexec version
  supports it; otherwise the resize is silently accepted.

  ## Backpressure

  Per-session output queue is capped at 4 MiB. If the browser relay is
  slow, oldest chunks are dropped and a `pty_error :backpressure_overflow`
  is emitted (session remains open).

  ## Wire protocol

  Inbound frames (from FrameRouter):
    - `{:pty_open_request, %{session_id, shell, cols, rows, cwd, env}}`
    - `{:pty_input, %{session_id, data}}`
    - `{:pty_resize, %{session_id, cols, rows}}`
    - `{:pty_close, %{session_id, exit_code}}`

  Outbound frames (to FrameRouter):
    - `{:pty_opened, %{session_id, pid: self()}}`
    - `{:pty_output, %{session_id, data}}`
    - `{:pty_close, %{session_id, exit_code}}`
    - `{:pty_error, %{session_id, reason}}`
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @max_output_queue_bytes 4 * 1024 * 1024

  # ── Default shell allowlists ─────────────────────────────────────────────────

  @unix_default_shells ["/bin/bash", "/bin/sh"]
  @windows_default_shells ["powershell.exe", "cmd.exe"]

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Route an inbound pty_* frame from the control plane."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # sessions: %{session_id => %{os_pid, port, queued_bytes}}
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_cast({:inbound, {:pty_open_request, payload}}, state) do
    session_id = payload[:session_id] || payload["session_id"]
    shell = payload[:shell] || payload["shell"] || default_shell()
    cols = payload[:cols] || payload["cols"] || 80
    rows = payload[:rows] || payload["rows"] || 24
    cwd = payload[:cwd] || payload["cwd"] || Path.expand("~")
    env = payload[:env] || payload["env"] || []

    case open_pty(session_id, shell, cols, rows, cwd, env) do
      {:ok, os_pid, port} ->
        Logger.info("[OC.Pty] opened session=#{session_id} shell=#{shell} pid=#{os_pid}")

        FrameRouter.send_frame({:pty_opened, %{session_id: session_id, pid: self()}})

        new_sessions =
          Map.put(state.sessions, session_id, %{
            os_pid: os_pid,
            port: port,
            queued_bytes: 0
          })

        {:noreply, %{state | sessions: new_sessions}}

      {:error, reason} ->
        Logger.warning("[OC.Pty] open failed session=#{session_id} reason=#{reason}")
        FrameRouter.send_frame({:pty_error, %{session_id: session_id, reason: reason}})
        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:pty_input, payload}}, state) do
    session_id = payload[:session_id] || payload["session_id"]
    data = payload[:data] || payload["data"] || ""

    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.debug("[OC.Pty] pty_input for unknown session=#{session_id}, dropping")
        {:noreply, state}

      %{os_pid: os_pid} ->
        send_to_os_pid(os_pid, data)
        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:pty_resize, payload}}, state) do
    session_id = payload[:session_id] || payload["session_id"]
    cols = payload[:cols] || payload["cols"] || 80
    rows = payload[:rows] || payload["rows"] || 24

    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      %{os_pid: os_pid} ->
        # Attempt resize via erlexec's winsize signal.
        # Falls back silently if the erlexec version doesn't support it.
        try do
          :exec.send(os_pid, {:winsize, rows, cols})
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:pty_close, payload}}, state) do
    session_id = payload[:session_id] || payload["session_id"]

    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      %{os_pid: os_pid} ->
        # Send SIGHUP to the shell to trigger graceful shutdown
        try do
          :exec.kill(os_pid, :sighup)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}
    end
  end

  def handle_cast({:inbound, _frame}, state), do: {:noreply, state}

  # ── Port / erlexec messages ──────────────────────────────────────────────────

  @impl true
  # erlexec stdout data
  def handle_info({:stdout, os_pid, data}, state) do
    session_id = find_session_by_os_pid(state.sessions, os_pid)

    if session_id do
      session = state.sessions[session_id]
      new_queued = session.queued_bytes + byte_size(data)

      if new_queued > @max_output_queue_bytes do
        Logger.warning("[OC.Pty] backpressure overflow session=#{session_id}, dropping chunk")

        FrameRouter.send_frame(
          {:pty_error, %{session_id: session_id, reason: :backpressure_overflow}}
        )

        # Reset queue counter — session stays open
        {:noreply, put_in(state.sessions[session_id].queued_bytes, 0)}
      else
        FrameRouter.send_frame({:pty_output, %{session_id: session_id, data: data}})
        {:noreply, put_in(state.sessions[session_id].queued_bytes, new_queued)}
      end
    else
      {:noreply, state}
    end
  end

  # erlexec process down — {exit_status, N} on non-zero / SIGTERM;
  # :normal or :shutdown when the shell exits cleanly via PTY on some platforms.
  def handle_info({:DOWN, os_pid, :process, _, {:exit_status, status}}, state) do
    emit_pty_close(os_pid, exit_status_to_code(status), state)
  end

  def handle_info({:DOWN, os_pid, :process, _, :normal}, state) do
    emit_pty_close(os_pid, 0, state)
  end

  def handle_info({:DOWN, os_pid, :process, _, :shutdown}, state) do
    emit_pty_close(os_pid, 0, state)
  end

  def handle_info({:DOWN, os_pid, :process, _, {:shutdown, _}}, state) do
    emit_pty_close(os_pid, 0, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: PTY spawning ────────────────────────────────────────────────────

  defp open_pty(session_id, shell, cols, rows, cwd, env) do
    case :os.type() do
      {:win32, _} ->
        Logger.warning(
          "[OC.Pty] session=#{session_id} Windows ConPTY not yet supported (TODO: issue #51)"
        )

        {:error, :pty_unavailable}

      {:unix, _} ->
        open_unix_pty(session_id, shell, cols, rows, cwd, env)
    end
  end

  defp open_unix_pty(_session_id, shell, cols, rows, cwd, env) do
    # erlexec is started HERE, on first PTY use, not as an OTP dependency at
    # boot. Its port program refuses to run as root, and as an auto-started
    # dependency that failure took the whole application down inside every
    # root container. Degrading here costs a PTY session; degrading there cost
    # the entire agent. See OptimalSystemAgent.System.Erlexec.
    with :ok <- OptimalSystemAgent.System.Erlexec.ensure_started(),
         true <- shell_allowed?(shell),
         resolved when is_binary(resolved) <- System.find_executable(shell) || shell,
         true <- File.exists?(resolved) do
      # Build env list for erlexec
      exec_env =
        env
        |> Enum.flat_map(fn
          {k, v} -> [{"#{k}", "#{v}"}]
          %{"key" => k, "value" => v} -> [{"#{k}", "#{v}"}]
          _ -> []
        end)

      exec_opts =
        [
          :pty,
          :stdin,
          :stdout,
          :monitor,
          {:cd, to_charlist(Path.expand(cwd))},
          {:winsz, {rows, cols}}
        ] ++ if exec_env == [], do: [], else: [{:env, exec_env}]

      try do
        case :exec.run(to_charlist(resolved) ++ ~c" -i", exec_opts) do
          {:ok, _, os_pid} ->
            {:ok, os_pid, nil}

          {:error, _reason} ->
            {:error, :spawn_failed}
        end
      rescue
        _ -> {:error, :spawn_failed}
      catch
        _, _ -> {:error, :spawn_failed}
      end
    else
      {:error, _erlexec_reason} -> {:error, :exec_unavailable}
      false -> {:error, :shell_not_allowed}
      _ -> {:error, :shell_not_allowed}
    end
  end

  defp shell_allowed?(shell) do
    allowed = read_allowed_shells()
    # Match by exact path or basename
    shell in allowed or Path.basename(shell) in Enum.map(allowed, &Path.basename/1)
  end

  defp read_allowed_shells do
    config_dir =
      Application.get_env(:optimal_system_agent, :config_dir, "~/.osa")
      |> Path.expand()

    toml_path = Path.join(config_dir, "open_computers.toml")

    # Try TOML config first; fall back to platform defaults
    case File.read(toml_path) do
      {:ok, content} ->
        case parse_pty_allowed_shells(content) do
          [_ | _] = shells -> shells
          _ -> default_allowed_shells()
        end

      {:error, _} ->
        default_allowed_shells()
    end
  end

  # Minimal TOML parser for the [pty] allowed_shells key.
  # Handles: allowed_shells = ["/bin/bash", "/bin/sh"]
  defp parse_pty_allowed_shells(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "[pty]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "[")))
    |> Enum.find_value(fn line ->
      case Regex.run(~r/allowed_shells\s*=\s*\[([^\]]*)\]/, line) do
        [_, list_str] ->
          list_str
          |> String.split(",")
          |> Enum.map(&(String.trim(&1) |> String.trim(~S("))))
          |> Enum.reject(&(&1 == ""))

        _ ->
          nil
      end
    end)
    |> case do
      nil -> []
      shells -> shells
    end
  end

  defp default_allowed_shells do
    case :os.type() do
      {:win32, _} -> @windows_default_shells
      _ -> @unix_default_shells
    end
  end

  defp default_shell do
    case :os.type() do
      {:win32, _} -> "powershell.exe"
      _ -> "/bin/bash"
    end
  end

  # Send input to the erlexec-managed OS process stdin (PTY input).
  defp send_to_os_pid(nil, _data), do: :ok

  defp send_to_os_pid(os_pid, data) when is_integer(os_pid) do
    try do
      :exec.send(os_pid, data)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp emit_pty_close(os_pid, exit_code, state) do
    session_id = find_session_by_os_pid(state.sessions, os_pid)

    if session_id do
      Logger.info("[OC.Pty] session=#{session_id} shell exited with code=#{exit_code}")
      FrameRouter.send_frame({:pty_close, %{session_id: session_id, exit_code: exit_code}})
      {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}
    else
      {:noreply, state}
    end
  end

  defp find_session_by_os_pid(sessions, os_pid) do
    Enum.find_value(sessions, fn {sid, session} ->
      if Map.get(session, :os_pid) == os_pid, do: sid
    end)
  end

  defp exit_status_to_code(status) when is_integer(status), do: status
  defp exit_status_to_code(_), do: -1
end
