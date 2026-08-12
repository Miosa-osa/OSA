defmodule OptimalSystemAgent.Shell.BackgroundTask do
  @moduledoc """
  A single supervised background shell command.

  MECHANISM (not interface): this GenServer owns one OS process spawned via a
  `Port` running `sh -c "<command> 2>&1"`. It accumulates the merged
  stdout/stderr stream into a bounded buffer, tracks lifecycle status, and can
  kill the underlying OS process on request.

  The process is registered by its background id in
  `OptimalSystemAgent.Shell.BackgroundRegistry` so callers can look it up and
  poll it by id (see `OptimalSystemAgent.Shell.BackgroundManager`).

  Lifecycle status:
    * `:running` — command still executing
    * `:done`    — exited with code 0
    * `:failed`  — exited with non-zero code
    * `:killed`  — killed on request (a SIGTERM/SIGKILL was sent)

  Completed tasks linger (so their output stays pollable) until a retention
  timer fires, at which point the worker stops and unregisters itself.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry OptimalSystemAgent.Shell.BackgroundRegistry

  # Cap the accumulated buffer so a chatty background command can't grow
  # unbounded in memory. We keep the HEAD of the output (matches the foreground
  # shell_execute truncation behaviour) and mark it truncated once the cap is hit.
  @default_max_bytes 524_288
  # Keep a completed task's output pollable for this long, then retire it.
  @default_retain_ms 3_600_000

  defstruct [
    :id,
    :command,
    :cwd,
    :session_id,
    :port,
    :os_pid,
    # `true` when `os_pid` is a `setsid -w` WRAPPER (this module spawned it), so
    # the group leader is one level down. `false` when the pid was adopted from
    # another spawner and IS the leader. Decides which ProcessGroup lookup to
    # use when reaping.
    :wrapper?,
    :started_at,
    :finished_at,
    :exit_code,
    status: :running,
    buffer: [],
    bytes: 0,
    truncated: false,
    notified: false,
    max_bytes: @default_max_bytes,
    retain_ms: @default_retain_ms
  ]

  # ── Public API (called by the manager) ───────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Return a snapshot map: accumulated output + status + metadata."
  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc "Send SIGTERM (then SIGKILL) to the OS process. Returns a snapshot."
  @spec kill(pid()) :: map()
  def kill(pid), do: GenServer.call(pid, :kill)

  defp via(id), do: {:via, Registry, {@registry, id}}

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    if Keyword.get(opts, :adopt, false) do
      init_adopt(opts)
    else
      init_spawn(opts)
    end
  end

  # Adopt an already-running OS process: the caller (a foreground shell_execute
  # loop) owns the live port and hands it over via `Port.connect/2` right after
  # start_link returns. We do NOT open a new port — we just record the existing
  # one and seed the buffer with whatever output was collected before hand-off.
  # Data/exit-status messages arrive once ownership transfers to us.
  defp init_adopt(opts) do
    id = Keyword.fetch!(opts, :id)
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.fetch!(opts, :cwd)
    port = Keyword.fetch!(opts, :port)
    os_pid = Keyword.get(opts, :os_pid)
    session_id = Keyword.get(opts, :session_id)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    retain_ms = Keyword.get(opts, :retain_ms, @default_retain_ms)
    initial = Keyword.get(opts, :initial, "")

    {buffer, bytes} =
      if is_binary(initial) and initial != "", do: {[initial], byte_size(initial)}, else: {[], 0}

    state = %__MODULE__{
      id: id,
      command: command,
      cwd: cwd,
      session_id: session_id,
      port: port,
      os_pid: os_pid,
      # An adopted pid is the group LEADER (shell_execute's `adopted_os_pid/1`
      # already looks through its own setsid wrapper), never a wrapper.
      wrapper?: false,
      started_at: DateTime.utc_now(),
      max_bytes: max_bytes,
      retain_ms: retain_ms,
      buffer: buffer,
      bytes: bytes,
      truncated: bytes >= max_bytes
    }

    # WS6: the advertised <output-file> must EXIST from the moment the task
    # does — a notification pointing at a missing file is worse than none.
    OptimalSystemAgent.Shell.TaskOutput.ensure(session_id, id)

    # Bound the per-session output dir on GROWTH: evict oldest-first past the
    # cap. Enforcing here (rather than only on :retire) means a crash, a
    # :brutal_kill shutdown, or a skipped retirement timer can never let the
    # file count run away. Files younger than the eviction floor are skipped, so
    # this can't remove a live task's output.
    OptimalSystemAgent.Shell.TaskOutput.sweep_session(session_id)

    # WS6: seed the on-disk output file with what the foreground run captured
    # before the Ctrl+B hand-off, so the file holds the FULL stream.
    if is_binary(initial) and initial != "" do
      OptimalSystemAgent.Shell.TaskOutput.append(session_id, id, initial)
    end

    {:ok, state}
  end

  defp init_spawn(opts) do
    id = Keyword.fetch!(opts, :id)
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.fetch!(opts, :cwd)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    retain_ms = Keyword.get(opts, :retain_ms, @default_retain_ms)
    session_id = Keyword.get(opts, :session_id)

    sh = OptimalSystemAgent.OS.Shell.executable()
    args = OptimalSystemAgent.OS.Shell.port_flags() ++ [command <> " 2>&1"]

    # PROCESS GROUP — spawn through `setsid -w` so the command and everything it
    # forks share one group we can reap as a unit. A background task is the
    # WORST case for the old single-pid kill: `npm run dev &`, a docker client,
    # a dev server. Killing the shell left every descendant holding its ports.
    # Same helper (and the same `killpg_safe?/1` guard) shell_execute uses.
    plan = OptimalSystemAgent.OS.ProcessGroup.spawn_plan(sh, args)

    port =
      Port.open(
        {:spawn_executable, plan.exe},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, plan.args},
          {:cd, cwd},
          # A bare Port.open hands the child the entire BEAM environment,
          # provider credentials included.
          {:env, OptimalSystemAgent.OS.Env.port_env()}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    # WS6: create the advertised <output-file> up front. It used to be created
    # lazily by the first `{:data, _}` chunk, so a silent command (or one that
    # had not printed yet) handed the model a path that did not exist.
    OptimalSystemAgent.Shell.TaskOutput.ensure(session_id, id)

    # Bound the per-session output dir on GROWTH: evict oldest-first past the
    # cap. Enforcing here (rather than only on :retire) means a crash, a
    # :brutal_kill shutdown, or a skipped retirement timer can never let the
    # file count run away. Files younger than the eviction floor are skipped, so
    # this can't remove a live task's output.
    OptimalSystemAgent.Shell.TaskOutput.sweep_session(session_id)

    state = %__MODULE__{
      id: id,
      command: command,
      cwd: cwd,
      session_id: session_id,
      port: port,
      os_pid: os_pid,
      wrapper?: plan.group?,
      started_at: DateTime.utc_now(),
      max_bytes: max_bytes,
      retain_ms: retain_ms
    }

    {:ok, state}
  rescue
    e ->
      {:stop, {:spawn_failed, Exception.message(e)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # WS6: mirror every chunk to the per-task disk file so the FULL output
    # survives the in-memory head-truncation and is readable via the read tool.
    OptimalSystemAgent.Shell.TaskOutput.append(state.session_id, state.id, data)
    {:noreply, append(state, data)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    status = if code == 0, do: :done, else: :failed
    # Preserve an explicit :killed status if a kill was already recorded.
    status = if state.status == :killed, do: :killed, else: status

    state = %{state | status: status, exit_code: code, finished_at: DateTime.utc_now(), port: nil}

    state = maybe_notify(state)

    # Retire after the retention window so output stays pollable for a while.
    Process.send_after(self(), :retire, state.retain_ms)
    {:noreply, state}
  end

  # Retention timer — stop the (already-completed) worker.
  def handle_info(:retire, %{status: :running} = state) do
    # Still running (shouldn't normally happen) — ignore and keep going.
    {:noreply, state}
  end

  def handle_info(:retire, state) do
    # Retire the on-disk output alongside the worker. This is deliberately tied
    # to the retention timer, not to completion: the <task-notification> hands
    # the model this exact path, so deleting at exit would race the consumer.
    # By the time :retire fires the task has been pollable for retain_ms (1 h).
    OptimalSystemAgent.Shell.TaskOutput.delete(state.session_id, state.id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, to_map(state), state}
  end

  def handle_call(:kill, _from, %{status: :running} = state) do
    do_kill(state.os_pid, state.wrapper?)

    state = %{
      state
      | status: :killed,
        finished_at: state.finished_at || DateTime.utc_now()
    }

    state = maybe_notify(state)

    # Ensure the worker is retired even if no exit_status arrives.
    Process.send_after(self(), :retire, state.retain_ms)
    {:reply, to_map(state), state}
  end

  def handle_call(:kill, _from, state) do
    # Already finished — nothing to kill; just report current state.
    {:reply, to_map(state), state}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp append(%{truncated: true} = state, _data), do: state

  defp append(state, data) do
    size = byte_size(data)

    if state.bytes + size > state.max_bytes do
      remaining = max(state.max_bytes - state.bytes, 0)
      kept = binary_part(data, 0, remaining)

      %{
        state
        | buffer: [kept | state.buffer],
          bytes: state.bytes + byte_size(kept),
          truncated: true
      }
    else
      %{state | buffer: [data | state.buffer], bytes: state.bytes + size}
    end
  end

  @doc false
  def do_kill(os_pid, wrapper? \\ false)

  def do_kill(nil, _wrapper?), do: :ok

  # Kill the command AND EVERYTHING IT SPAWNED.
  #
  # This used to be `kill -TERM <pid>` immediately followed by `kill -KILL
  # <pid>`: one pid, no process group, and no grace window between the two
  # signals — so the TERM was functionally a KILL, and every descendant of a
  # background `npm run dev` / `docker run` survived as an orphan still holding
  # its ports. Exactly the defect already fixed in shell_execute.
  #
  # Which lookup applies depends on how we got the pid:
  #
  #   * `wrapper?: true`  — we spawned it, so `os_pid` is the `setsid -w`
  #     wrapper and the leader is its child: `resolve_pgid/1`.
  #   * `wrapper?: false` — the pid was adopted from a foreground
  #     shell_execute, which already hands over the group LEADER: `pgid_of/1`.
  #
  # Both results go through `ProcessGroup.killpg_safe?/1` (inside
  # `terminate_group/2`), which refuses pgid <= 1 and this node's own group. A
  # pid that was never `setsid`-ed reports the BEAM's group, so that guard is
  # what stops an adopted-without-setsid task from signalling the agent itself;
  # it degrades to the single-pid path instead.
  # Kill the command AND EVERYTHING IT SPAWNED.
  #
  # This used to be `kill -TERM <pid>` immediately followed by `kill -KILL
  # <pid>`: one pid, no process group, and no grace window between the two
  # signals — so the TERM was functionally a KILL, and every descendant of a
  # background `npm run dev` / `docker run` survived as an orphan still holding
  # its ports. Exactly the defect already fixed in shell_execute.
  #
  # Which lookup applies depends on how we got the pid:
  #
  #   * `wrapper?: true`  — we spawned it, so `os_pid` is the `setsid -w`
  #     wrapper and the leader is its child: `resolve_pgid/1`.
  #   * `wrapper?: false` — the pid was adopted from a foreground
  #     shell_execute, which already hands over the group LEADER: `pgid_of/1`.
  #
  # Both results go through `ProcessGroup.killpg_safe?/1` (inside
  # `terminate_group/2`), which refuses pgid <= 1 and this node's own group. A
  # pid that was never `setsid`-ed reports the BEAM's group, so that guard is
  # what stops an adopted-without-setsid task from signalling the agent itself;
  # it degrades to the single-pid path instead.
  def do_kill(os_pid, wrapper?) do
    alias OptimalSystemAgent.OS.ProcessGroup

    case :os.type() do
      {:win32, _} ->
        _ =
          System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)

      _ ->
        pgid =
          if wrapper?, do: ProcessGroup.resolve_pgid(os_pid), else: ProcessGroup.pgid_of(os_pid)

        case pgid do
          nil ->
            ProcessGroup.terminate_pid(os_pid)

          pgid ->
            case ProcessGroup.terminate_group(pgid) do
              # The group is gone; the wrapper (which is NOT in that group when
              # setsid was used) still needs reaping, with no second grace wait.
              :ok -> ProcessGroup.terminate_pid(os_pid, 0)
              {:error, :unsafe_pgid} -> ProcessGroup.terminate_pid(os_pid)
            end
        end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Broadcast a terminal event on the parent session topic so BOTH the
  # BackgroundNotifier (→ injects "[Background command … completed (exit N)]"
  # into the parent Loop) and the HTTP SSE loop (→ TUI toast + live count) pick
  # it up. Guarded so a PubSub failure never crashes the worker before it
  # schedules :retire. No-op when the command wasn't started with a session.
  # Exactly-once completion notification (WS6). Guards the in-process double
  # (kill followed by the port's exit_status). The cross-process race — a
  # bash_output poll vs this broadcast — is arbitrated separately by the
  # shared Agent.TaskNotifications.mark_notified check-and-set.
  defp maybe_notify(%{notified: true} = state), do: state

  defp maybe_notify(state) do
    notify_completion(state)
    %{state | notified: true}
  end

  defp output_file(%{session_id: nil}), do: nil

  defp output_file(state),
    do: OptimalSystemAgent.Shell.TaskOutput.path(state.session_id, state.id)

  defp notify_completion(%{session_id: nil}), do: :ok

  defp notify_completion(state) do
    tail = state |> output_string() |> tail_bytes(2000)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :background_command_completed,
         background_id: state.id,
         command: state.command,
         status: state.status,
         exit_code: state.exit_code,
         output_tail: tail,
         output_file: output_file(state),
         session_id: state.session_id,
         running_count: OptimalSystemAgent.Shell.BackgroundManager.running_count()
       }}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp tail_bytes(str, n) when byte_size(str) <= n, do: str
  defp tail_bytes(str, n), do: binary_part(str, byte_size(str) - n, n)

  defp output_string(state) do
    state.buffer |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp to_map(state) do
    %{
      id: state.id,
      command: state.command,
      cwd: state.cwd,
      session_id: state.session_id,
      status: state.status,
      exit_code: state.exit_code,
      output: output_string(state),
      output_file: output_file(state),
      bytes: state.bytes,
      truncated: state.truncated,
      started_at: state.started_at,
      finished_at: state.finished_at
    }
  end
end
