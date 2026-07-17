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
    :started_at,
    :finished_at,
    :exit_code,
    status: :running,
    buffer: [],
    bytes: 0,
    truncated: false,
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
    id = Keyword.fetch!(opts, :id)
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.fetch!(opts, :cwd)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    retain_ms = Keyword.get(opts, :retain_ms, @default_retain_ms)
    session_id = Keyword.get(opts, :session_id)

    sh = OptimalSystemAgent.OS.Shell.executable()

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, OptimalSystemAgent.OS.Shell.port_flags() ++ [command <> " 2>&1"]},
          {:cd, cwd}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %__MODULE__{
      id: id,
      command: command,
      cwd: cwd,
      session_id: session_id,
      port: port,
      os_pid: os_pid,
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
    {:noreply, append(state, data)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    status = if code == 0, do: :done, else: :failed
    # Preserve an explicit :killed status if a kill was already recorded.
    status = if state.status == :killed, do: :killed, else: status

    state = %{state | status: status, exit_code: code, finished_at: DateTime.utc_now(), port: nil}

    notify_completion(state)

    # Retire after the retention window so output stays pollable for a while.
    Process.send_after(self(), :retire, state.retain_ms)
    {:noreply, state}
  end

  # Retention timer — stop the (already-completed) worker.
  def handle_info(:retire, %{status: :running} = state) do
    # Still running (shouldn't normally happen) — ignore and keep going.
    {:noreply, state}
  end

  def handle_info(:retire, state), do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, to_map(state), state}
  end

  def handle_call(:kill, _from, %{status: :running} = state) do
    do_kill(state.os_pid)

    state = %{
      state
      | status: :killed,
        finished_at: state.finished_at || DateTime.utc_now()
    }

    notify_completion(state)

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

  defp do_kill(nil), do: :ok

  defp do_kill(os_pid) do
    # SIGTERM first for a graceful stop, then SIGKILL as a fallback.
    _ = System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    _ = System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # Broadcast a terminal event on the parent session topic so BOTH the
  # BackgroundNotifier (→ injects "[Background command … completed (exit N)]"
  # into the parent Loop) and the HTTP SSE loop (→ TUI toast + live count) pick
  # it up. Guarded so a PubSub failure never crashes the worker before it
  # schedules :retire. No-op when the command wasn't started with a session.
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
      status: state.status,
      exit_code: state.exit_code,
      output: output_string(state),
      bytes: state.bytes,
      truncated: state.truncated,
      started_at: state.started_at,
      finished_at: state.finished_at
    }
  end
end
