defmodule OptimalSystemAgent.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for a local MCP server subprocess.

  Wraps an Erlang `Port` opened with `{:spawn_executable, exe}` in `:binary`
  mode with `:exit_status`. MCP frames messages as newline-delimited JSON, so
  we buffer partial lines and emit one `{:mcp_message, ref, line}` per
  complete line.

  ## stderr routing

  stderr must NEVER merge into the JSON stdout channel (no `:stderr_to_stdout`
  on the port). By default a `:spawn_executable` child inherits the daemon's
  fd 2, so a misconfigured MCP server's npx/npm noise ("Cannot find package
  'zod'", EPIPE, executable-not-found) sprays straight into the daemon's
  console/backend.log and reads as a broken install. To keep boot calm we wrap
  the child in a tiny `sh -c 'exec "$@" 2>>LOG'` so its stderr is redirected to
  the MCP stderr log (`<config_dir>/logs/mcp-stderr.log`, best-effort, falling
  back to `/dev/null`) — off the console but still available for debugging. The
  `exec` keeps the child's pid stable so the process-group reaping below is
  unaffected. When `sh` is unavailable we spawn the command unchanged. Non-JSON
  lines that arrive on stdout are still surfaced to `Logger` at debug.

  On owner death or port exit the port is closed and `{:mcp_closed, ref, _}`
  is delivered. The GenServer traps exits so it can `Port.close/1` cleanly.

  ## Descendant-process reaping

  A plain `Port.close/1` sends `SIGKILL` only to the *direct* child. Real MCP
  servers are usually launched via a wrapper (`npx` → `node`, `uvx` → `python`,
  a shell one-liner…), so the direct child forks grandchildren that a bare
  close orphans — they leak, keep ports open, and pin memory. Following grok's
  `SafeTokioChildProcess`, we launch the child under `setsid -w` so it becomes
  a session/process-group **leader** in its own group, then on teardown
  `killpg` (`kill -KILL -<pgid>`) the whole group so grandchildren die with it.
  `setsid -w` keeps the wrapper alive (it waits on the child), which lets us
  resolve the child's stable pgid deterministically. When `setsid` is
  unavailable (e.g. a bare macOS box) we degrade gracefully to a plain spawn
  with direct-child-only cleanup.

  Implements `OptimalSystemAgent.MCP.Transport`.
  """

  @behaviour OptimalSystemAgent.MCP.Transport

  use GenServer
  require Logger

  # Hard cap on the unframed inbound buffer. An MCP server that streams a very
  # large result, or dies/hangs mid-frame without a trailing newline, would
  # otherwise grow state.buffer without bound and exhaust BEAM memory. When the
  # accumulated buffer with no newline exceeds this, we drop the oversized frame.
  @max_frame_bytes 16 * 1024 * 1024

  # Delay before probing for the child's pgid. `setsid -w` forks the real child
  # a beat after spawn; a short probe lets that settle before we cache the group.
  @pgid_probe_ms 200

  defstruct [:port, :owner, :ref, :name, buffer: "", exe: nil, reap: false, pgid: nil]

  # ── Transport API ─────────────────────────────────────────────────────

  @impl OptimalSystemAgent.MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl OptimalSystemAgent.MCP.Transport
  def send_message(transport, message) when is_binary(message) do
    GenServer.call(transport, {:send, message})
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    name = Keyword.get(opts, :name, command)

    case resolve_executable(command) do
      {:ok, exe} ->
        # `:env` is an OVERLAY, not a replacement: building it from the server's
        # configured `env` alone still handed the child EVERYTHING else in the
        # BEAM's environment — and an MCP server is third-party code the
        # operator installed, not code OSA controls. Scrub first; the server's
        # own configured vars are applied on top, so a server that is meant to
        # receive a credential still receives exactly the one it was given.
        port_env = OptimalSystemAgent.OS.Env.port_env(Enum.to_list(env))

        # Redirect the child's stderr off the daemon console AND wrap it under
        # `setsid -w` so it leads its own process group for teardown reaping.
        # Falls back gracefully when `sh`/`setsid` are missing.
        {spawn_exe, spawn_args, reap?} = build_spawn(exe, args)

        port =
          Port.open(
            {:spawn_executable, spawn_exe},
            [
              :binary,
              :exit_status,
              :hide,
              {:args, spawn_args},
              {:env, port_env}
            ]
          )

        if reap?, do: Process.send_after(self(), :cache_pgid, @pgid_probe_ms)

        {:ok, %__MODULE__{port: port, owner: owner, ref: ref, name: name, exe: exe, reap: reap?}}

      {:error, reason} ->
        {:stop, {:executable_not_found, command, reason}}
    end
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when is_port(port) do
    try do
      Port.command(port, [message, "\n"])
      {:reply, :ok, state}
    rescue
      e -> {:reply, {:error, Exception.message(e)}, state}
    catch
      :error, reason -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, _message}, _from, state) do
    {:reply, {:error, :no_port}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Opportunistically cache the pgid on first traffic — by the time a server
    # speaks, `setsid -w` has certainly forked the real child.
    state = ensure_pgid(state)

    {lines, buffer} = split_lines(state.buffer <> data)
    Enum.each(lines, &deliver_line(&1, state))

    # Drop an oversized unframed remainder (no newline yet) instead of letting
    # the buffer grow without bound and OOM the node.
    buffer =
      if byte_size(buffer) > @max_frame_bytes do
        Logger.warning(
          "[mcp.stdio] Dropping oversized frame (#{byte_size(buffer)} bytes, no newline) " <>
            "from #{state.name || "server"}; buffer reset"
        )

        ""
      else
        buffer
      end

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # The wrapper (and thus the leader) has exited; reap any lingering
    # grandchildren via the cached group before we forget it.
    reap_group(state)
    notify_closed(state, {:exit_status, status})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(:cache_pgid, state) do
    {:noreply, ensure_pgid(state)}
  end

  # The OWNER (the process that started us, and the one we deliver to) died —
  # shut down and close the port. We must match on the owner specifically: this
  # GenServer traps exits and shells out via `System.cmd` (pgrep/ps for pgid
  # resolution), whose transient ports emit `{:EXIT, port, :normal}` when they
  # finish — those are NOT our owner dying and must be ignored, or a routine
  # pgid probe would tear the transport down (and reap the live child).
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port} = state) when is_port(port) do
    # Reap the whole process group FIRST (while the leader is still alive to
    # anchor the pgid), then close the port. Resolve lazily here as a fallback
    # in case first-traffic caching never happened.
    state |> ensure_pgid() |> reap_group()

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, state) do
    reap_group(state)
    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Deliver a complete inbound line. Blank lines are ignored; non-JSON lines
  # (which some servers emit as diagnostics on stdout) are logged, not sent.
  defp deliver_line("", _state), do: :ok

  defp deliver_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :ok

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        send(state.owner, {:mcp_message, state.ref, trimmed})

      true ->
        Logger.debug("[MCP.Stdio:#{state.name}] non-JSON stdout: #{trimmed}")
    end
  end

  defp notify_closed(%{owner: owner, ref: ref}, reason) do
    send(owner, {:mcp_closed, ref, reason})
  end

  # Split accumulated data on newlines; return {complete_lines, remainder}.
  defp split_lines(data) do
    parts = String.split(data, "\n")

    case Enum.reverse(parts) do
      [last | rev_complete] -> {Enum.reverse(rev_complete), last}
      [] -> {[], ""}
    end
  end

  # ── Process-group reaping ─────────────────────────────────────────────

  # Build the final `{spawn_exe, spawn_args, reap?}` for `Port.open`, applied
  # inside-out:
  #
  #   1. `wrap_stderr` wraps the command in `sh -c 'exec "$@" 2>>LOG'` so the
  #      child's stderr lands in the MCP stderr log instead of the daemon's
  #      inherited fd 2. `exec` keeps the child's pid stable, so the pgid
  #      resolution below still finds the same leader. stdout (the JSON channel)
  #      is untouched — stderr is NEVER merged into it.
  #   2. `setsid -w` makes that child a process-group leader so the whole tree
  #      can be reaped on teardown. When setsid is missing we spawn directly and
  #      skip reaping (best-effort, direct-child-only cleanup, as before).
  defp build_spawn(exe, args) do
    {exe, args} = wrap_stderr(exe, args)

    case System.find_executable("setsid") do
      nil -> {exe, args, false}
      setsid -> {setsid, ["-w", exe | args], true}
    end
  end

  # Redirect the child's stderr to the MCP stderr log via a tiny `sh` wrapper
  # that `exec`s the real command (no extra process layer; pid stays stable for
  # pgid resolution). When `sh` is unavailable the command is spawned unchanged
  # (its stderr stays inherited — best-effort, matching the setsid fallback).
  defp wrap_stderr(exe, args) do
    case System.find_executable("sh") do
      nil ->
        {exe, args}

      sh ->
        script = ~s(exec "$@" 2>>#{shell_quote(stderr_log_path())})
        {sh, ["-c", script, "sh", exe | args]}
    end
  end

  # Absolute path to the shared MCP child-stderr log, created best-effort. If the
  # log dir cannot be made we fall back to /dev/null so stderr is still kept off
  # the daemon console.
  defp stderr_log_path do
    dir = Path.join(config_dir(), "logs")

    case File.mkdir_p(dir) do
      :ok -> Path.join(dir, "mcp-stderr.log")
      _ -> "/dev/null"
    end
  rescue
    _ -> "/dev/null"
  end

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end

  # POSIX single-quote a path for safe embedding in the `sh -c` script.
  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  # Resolve and cache the child's process-group id once, from the (still alive)
  # `setsid -w` wrapper's os_pid. No-op when reaping is off or already cached.
  defp ensure_pgid(%{reap: false} = state), do: state
  defp ensure_pgid(%{pgid: pgid} = state) when is_integer(pgid), do: state

  defp ensure_pgid(%{port: port} = state) when is_port(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         pgid when is_integer(pgid) <- resolve_pgid(os_pid) do
      %{state | pgid: pgid}
    else
      _ -> state
    end
  end

  defp ensure_pgid(state), do: state

  # The wrapper's sole child is the group leader; its pid == its pgid.
  defp resolve_pgid(os_pid) do
    with [child | _] <- pgrep_children(os_pid),
         {out, 0} <- System.cmd("ps", ["-o", "pgid=", "-p", child], stderr_to_stdout: true),
         {pgid, _} <- Integer.parse(String.trim(out)) do
      pgid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp pgrep_children(os_pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  rescue
    _ -> []
  end

  # SIGKILL the whole process group (leader + grandchildren). `kill -KILL -<pgid>`
  # targets a group; guarded so a degenerate pgid can never signal init or this
  # very node's own group.
  defp reap_group(%{pgid: pgid}) when is_integer(pgid) and pgid > 1 do
    if killpg_safe?(pgid) do
      _ = System.cmd("kill", ["-s", "KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp reap_group(_state), do: :ok

  # Never killpg our own group (would SIGKILL the BEAM) or a group id ≤ 1.
  defp killpg_safe?(pgid) do
    pgid > 1 and pgid != own_pgid()
  end

  defp own_pgid do
    self_pid = :os.getpid() |> List.to_string()

    case System.cmd("ps", ["-o", "pgid=", "-p", self_pid], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pgid, _} -> pgid
          _ -> -1
        end

      _ ->
        -1
    end
  rescue
    _ -> -1
  end

  # Resolve a command to an absolute executable path. Absolute/relative paths
  # with a slash are used as-is; bare names are looked up on PATH.
  defp resolve_executable(command) do
    cond do
      String.contains?(command, "/") ->
        if File.exists?(command), do: {:ok, command}, else: {:error, :enoent}

      true ->
        case System.find_executable(command) do
          nil -> {:error, :not_on_path}
          path -> {:ok, path}
        end
    end
  end
end
