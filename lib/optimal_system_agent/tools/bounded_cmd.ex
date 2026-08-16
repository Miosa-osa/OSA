defmodule OptimalSystemAgent.Tools.BoundedCmd do
  @moduledoc """
  Run a subprocess under a deadline, kill its whole process group when the
  deadline fires, and give an honest answer about what did not happen.

  ## Why this exists

  `System.cmd/3` takes no timeout. A subprocess that blocks forever — `ssh` to a
  host that is up but not answering, `docker exec` into a container whose
  runtime has wedged, `diff` on a FIFO or a stalled NFS mount, `rg` walking a
  dead SSHFS mount, `xdotool windowactivate --sync` waiting on a window manager
  that never replies — never returns, and nothing above it has a deadline
  either: `:tool_timeout_ms` is `:infinity` **by design** (see
  `Agent.Loop.LongRunningToolTest`) and the loop runs the turn on its own stack.
  One wedged subprocess takes the whole session with it until the 24h
  `GenServer.call` backstop. That is how a live `rg` call held a turn for 1h51m.

  The bound is on the SUBPROCESS, never on the turn. A wall-clock cap on a turn
  punishes work for taking long; this caps one `execve` that is provably
  producing nothing. `:max_iterations` remains the only thing that punishes a
  turn, and it punishes it for going nowhere rather than for going slowly.

  ## Why `Port.open/2` and not `System.cmd/3`

  The first version of this module wrapped `System.cmd/3` in a supervised task
  and killed the task on expiry. That freed the CALLER and left the child
  running. Measured, not assumed: after the deadline fired and the task was
  `:brutal_kill`ed, `ps` still showed the child. `Task.shutdown/2` kills an
  Elixir process and closes the port, which closes the child's pipes — and a
  child blocked in `read(2)` on a dead mount, or in `connect(2)` to a
  black-holed host, does not care that its stdout went away.

  So a long session accumulated one orphan per wedged call, invisibly. Reaping
  needs the child's os_pid, which `System.cmd/3` does not expose, which is why
  this runs `Port.open/2` directly.

  Killing the direct child is not enough either. The shape that actually leaks
  is `sh -c "..."` spawning a grandchild: signal the shell and the grandchild
  survives, reparented to init, still holding whatever wedged it. So the spawn
  goes through `OS.ProcessGroup.spawn_plan/2` (`setsid -w`), which puts the
  command in its own session, and expiry signals the negative pgid so the kernel
  delivers to the whole tree. That is the same mechanism — and the same
  `killpg_safe?/1` guard against signalling pgid 0, pgid 1, or the BEAM's own
  group — that `shell_execute` and the MCP stdio transport already use.

  ## The part that matters most

  On expiry this reports an **incomplete operation that names itself and its
  target**, and it deliberately does not substitute a plausible-looking result.
  `ssh` to an unreachable host quietly returning empty output would be a silent
  wrong answer one layer above the hang — the model reads "no output" as "the
  command produced nothing", which is a fact about the remote host it has no
  evidence for. Killing the tree and saying so is the only outcome that cannot
  be mistaken for a measurement.

  A reap that FAILS does not change that answer. If `setsid` is missing, or the
  pgid cannot be resolved, or the guard refuses the group, the caller still gets
  its `{:timeout, message}` and the turn still continues. A leaked process is a
  bug; a crashed turn is worse.

  ## Differences from `System.cmd/3`, deliberately

  Behaviour is preserved where callers depend on it — binary output, the
  `{output, status}` shape via `cmd/3`, `:stderr_to_stdout`, `:cd`, `:env`
  overrides on top of the inherited environment. Two things differ on purpose:

    * **A missing executable is a RESULT, not a raise.** `System.cmd/3` raises
      `ErlangError` with `:enoent`; under a `setsid` wrapper the wrapper runs
      and exits 127 instead, so there is nothing to rescue. This checks for the
      executable up front and returns `{:ok, "executable not found: <exe>", 127}`,
      which keeps every caller's "(is xdotool installed?)" style message
      informative instead of reporting a bare exit 1.
    * **Output is uncapped**, matching `System.cmd/3`. Callers that need a cap
      (`shell_execute` does) already have their own.
  """
  require Logger

  alias OptimalSystemAgent.OS.ProcessGroup

  # Matches `shell_execute` and the old `file_grep` constant. Generous by
  # design: every call this wraps is either local and near-instant, or remote
  # and bounded by its own connect timeout. Anything that reaches 120s is
  # wedged, not slow.
  @default_timeout_ms 120_000

  @typedoc """
  `{:ok, output, exit_status}` when the process ran to completion — a non-zero
  status is a RESULT, not a failure of this wrapper, and is passed through.
  `{:timeout, message}` when the deadline fired: the tree was signalled and
  nothing was learned.
  """
  @type result :: {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}

  @typedoc "What the reap managed to do. Reported through telemetry, never to the model."
  @type reap :: :group | :pid | :none

  @doc """
  Run `exe` with `args` under a deadline.

  Options:

    * `:label` — what operation this is, in the words the caller would use
      (`"ssh"`, `"docker exec"`, `"diff"`). Appears in the expiry message.
    * `:target` — what it was operating ON (a host, a container id, a path).
      Appears in the expiry message. This is the half that makes the report
      actionable: "ssh timed out" sends the model looking at ssh, "ssh to
      build-07 timed out" sends it looking at build-07.
    * `:timeout_ms` — override the deadline. `:infinity` restores unbounded
      behaviour for an operator who wants it.
    * `:stderr_to_stdout` — default `true`, as every current caller wants.
    * `:cd`, `:env` — forwarded, with `:env` accepting `System.cmd/3`'s binary
      pairs and converting them for the port.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(exe, args, opts \\ []) when is_binary(exe) and is_list(args) do
    label = Keyword.get(opts, :label, exe)
    target = Keyword.get(opts, :target)
    timeout = Keyword.get(opts, :timeout_ms, timeout_ms())

    case System.find_executable(exe) do
      nil ->
        # `System.cmd/3` would raise :enoent here. Under a `setsid` wrapper
        # nothing raises — the wrapper runs and exits 127 — so the absence is
        # reported as itself rather than as an opaque failure. Callers print
        # this verbatim, which is why it names the binary.
        {:ok, "executable not found: #{exe}", 127}

      resolved ->
        spawn_and_wait(resolved, args, label, target, timeout, opts)
    end
  rescue
    e ->
      Logger.debug("[BoundedCmd] #{exe} could not be spawned: #{inspect(e)}")
      {:ok, "could not start #{exe}: #{Exception.message(e)}", 1}
  catch
    kind, reason ->
      Logger.debug("[BoundedCmd] #{exe} caught #{kind}: #{inspect(reason)}")
      {:ok, "could not start #{exe}", 1}
  end

  defp spawn_and_wait(exe, args, label, target, timeout, opts) do
    plan = ProcessGroup.spawn_plan(exe, args)
    port = Port.open({:spawn_executable, plan.exe}, port_opts(plan, opts))

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    collect(port, os_pid, plan, label, target, timeout, [])
  end

  defp port_opts(plan, opts) do
    base = [:binary, :exit_status, :hide, {:args, plan.args}]

    base =
      if Keyword.get(opts, :stderr_to_stdout, true),
        do: [:stderr_to_stdout | base],
        else: base

    base =
      case Keyword.get(opts, :cd) do
        nil -> base
        dir -> [{:cd, dir} | base]
      end

    case Keyword.get(opts, :env) do
      nil ->
        base

      env when is_list(env) ->
        # `System.cmd/3` takes binary pairs; the port wants charlists. Both
        # inherit the BEAM environment and apply these as OVERRIDES, so the
        # semantics carry over unchanged — which matters for the adapters,
        # whose commands need the inherited `DISPLAY` / `WAYLAND_DISPLAY`.
        [{:env, Enum.map(env, &to_env_pair/1)} | base]
    end
  end

  defp to_env_pair({k, v}) when is_binary(k) and is_binary(v),
    do: {String.to_charlist(k), String.to_charlist(v)}

  defp to_env_pair({k, false}) when is_binary(k), do: {String.to_charlist(k), false}
  defp to_env_pair(other), do: other

  # Accumulate output until the process exits or the deadline fires.
  #
  # `deadline` is absolute rather than a per-receive timeout: a chatty command
  # that emits a chunk every second would otherwise reset its own deadline on
  # every chunk and never expire, which is exactly the wedge a streaming
  # `docker` or `ssh` produces.
  defp collect(port, os_pid, plan, label, target, timeout, acc) do
    deadline = deadline_at(timeout)
    do_collect(port, os_pid, plan, label, target, timeout, deadline, acc)
  end

  defp do_collect(port, os_pid, plan, label, target, timeout, deadline, acc) do
    receive do
      {^port, {:data, chunk}} ->
        do_collect(port, os_pid, plan, label, target, timeout, deadline, [chunk | acc])

      {^port, {:exit_status, status}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining(deadline) ->
        reap = reap(port, os_pid, plan)
        report_expiry(label, target, timeout, reap)
        {:timeout, expiry_message(label, target, timeout)}
    end
  end

  defp deadline_at(:infinity), do: :infinity
  defp deadline_at(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  # ── The reap ──────────────────────────────────────────────────────────────

  # Kill the whole tree, then close the port.
  #
  # Order matters. The signal goes FIRST, while the port is still open and the
  # os_pid is still resolvable — closing the port first would leave us holding
  # nothing to signal, which is precisely the state the `System.cmd/3` version
  # was permanently in.
  #
  # Never raises. A reap that cannot be performed still lets the caller report
  # its incomplete result and the turn continue; the process leaks and the
  # telemetry says so.
  defp reap(port, os_pid, plan) do
    outcome = signal_tree(os_pid, plan)
    close(port)
    outcome
  rescue
    e ->
      Logger.debug("[BoundedCmd] reap failed: #{inspect(e)}")
      :none
  catch
    kind, reason ->
      Logger.debug("[BoundedCmd] reap caught #{kind}: #{inspect(reason)}")
      :none
  end

  defp signal_tree(nil, _plan), do: :none

  defp signal_tree(os_pid, %{group?: true}) do
    # `resolve_pgid/1` looks one level DOWN from the `setsid -w` wrapper at the
    # real command, which is the group leader. Signalling the negative pgid is
    # what reaches a grandchild — the `sh -c "cmd | other"` shape that leaks
    # under a plain single-pid kill.
    case ProcessGroup.resolve_pgid(os_pid) do
      nil ->
        # The group could not be established. Fall back rather than guess: an
        # unresolved pgid routed into killpg is how you SIGKILL your own BEAM.
        single_pid(os_pid, ProcessGroup.leader_pid(os_pid))

      pgid ->
        case ProcessGroup.terminate_group(pgid) do
          :ok ->
            # The wrapper is in the group and dies with it, but reap it by pid
            # too — `setsid -w` that has already reaped its child is no longer
            # a group member and would otherwise linger.
            _ = ProcessGroup.terminate_pid(os_pid, 0)
            :group

          {:error, :unsafe_pgid} ->
            single_pid(os_pid, ProcessGroup.leader_pid(os_pid))
        end
    end
  end

  defp signal_tree(os_pid, _plan) do
    # No `setsid` on this machine (Windows, a minimal container). One pid is all
    # there is to signal, and a grandchild will survive. Recorded as `:pid` so
    # the difference is visible in telemetry rather than assumed away.
    single_pid(os_pid, nil)
  end

  defp single_pid(wrapper_pid, leader_pid) do
    for pid <- Enum.uniq(Enum.reject([leader_pid, wrapper_pid], &is_nil/1)) do
      ProcessGroup.terminate_pid(pid)
    end

    :pid
  end

  defp close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    flush(port)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The port ran in the CALLER's process, so any chunk that arrived between the
  # deadline and the close is sitting in the caller's mailbox. Left there it
  # would be delivered to whatever that process receives next — and for a tool
  # that runs inline in the Loop GenServer, "whatever it receives next" is a
  # `handle_info` that has no clause for it.
  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp report_expiry(label, target, timeout, reap) do
    :telemetry.execute(
      [:osa, :bounded_cmd, :timeout],
      %{count: 1, timeout_ms: if(is_integer(timeout), do: timeout, else: 0)},
      %{label: label, target: target, reap: reap}
    )

    level = if reap == :none, do: :warning, else: :info

    Logger.log(
      level,
      "[BoundedCmd] #{label}#{if target, do: " on #{target}", else: ""} expired; " <>
        case reap do
          :group -> "process group reaped"
          :pid -> "reaped by pid (no process group — a grandchild may survive)"
          :none -> "COULD NOT REAP — the subprocess is leaked"
        end
    )

    :ok
  rescue
    _ -> :ok
  end

  # ── Public surface ────────────────────────────────────────────────────────

  @doc """
  `run/3` reduced to `System.cmd/3`'s own `{output, status}` shape, with the
  expiry message delivered AS the output and a non-zero status.

  For callers whose surrounding code already treats a non-zero status as "this
  did not work" and surfaces the output verbatim. Callers that branch on the
  distinction should use `run/3` and match `{:timeout, _}` themselves.
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(exe, args, opts \\ []) do
    case run(exe, args, opts) do
      {:ok, output, status} -> {output, status}
      {:timeout, message} -> {message, 124}
    end
  end

  @doc """
  The message an expired subprocess reports.

  Public so the phrasing can be asserted rather than string-matched from a test
  that would drift away from it.
  """
  @spec expiry_message(String.t(), String.t() | nil, timeout()) :: String.t()
  def expiry_message(label, target, timeout) do
    seconds = if is_integer(timeout), do: "#{div(timeout, 1000)}s", else: "its deadline"

    on = if target in [nil, ""], do: "", else: " on #{target}"

    "#{label}#{on} did not finish within #{seconds} and was stopped. " <>
      "The operation did NOT complete, so this is not evidence about#{if on == "", do: " the target", else: on} — " <>
      "no output was produced because the process was killed, not because there was none. " <>
      "An unreachable host, a wedged container runtime, a stalled network mount or a " <>
      "window manager that never answered all look like this."
  end

  @doc "The default deadline for one wrapped subprocess, in ms."
  @spec timeout_ms() :: timeout()
  def timeout_ms do
    case Application.get_env(:optimal_system_agent, :bounded_cmd_timeout_ms, @default_timeout_ms) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end
end
