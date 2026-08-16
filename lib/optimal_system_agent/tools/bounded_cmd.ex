defmodule OptimalSystemAgent.Tools.BoundedCmd do
  @moduledoc """
  `System.cmd/3` with a deadline, and an honest answer when the deadline fires.

  ## Why this exists

  `System.cmd/3` takes no timeout. A subprocess that blocks forever — `ssh` to a
  host that is up but not answering, `docker exec` into a container whose
  runtime has wedged, `diff` on a FIFO or a stalled NFS mount, `xdotool
  windowactivate --sync` waiting on a window manager that never replies — never
  returns, and nothing above it has a deadline either: `:tool_timeout_ms` is
  `:infinity` **by design** (see `Agent.Loop.LongRunningToolTest`) and the loop
  runs the turn on its own stack. One wedged subprocess takes the whole session
  with it until the 24h `GenServer.call` backstop. That is how a live `rg` call
  held a turn for 1h51m.

  The bound belongs on the SUBPROCESS, never on the turn. A wall-clock cap on a
  turn punishes work for taking long; this caps one `execve` that is provably
  producing nothing. `:max_iterations` remains the only thing that punishes a
  turn, and it punishes it for going nowhere rather than for going slowly.

  ## The part that matters most

  On expiry this reports an **incomplete operation that names itself and its
  target**, and it deliberately does not substitute a plausible-looking result.
  `ssh` to an unreachable host quietly returning empty output would be a
  silent wrong answer one layer above the hang — the model reads "no output" as
  "the command produced nothing", which is a fact about the remote host it has
  no evidence for. Killing the process and saying so is the only outcome that
  cannot be mistaken for a measurement.

  ## What this does NOT do, measured

  It releases the CALLER. It does not reap the OS process. `Task.shutdown/2`
  kills the Elixir process and closes the port, which closes the child's pipes —
  and a child blocked in `sleep`, on a FIFO, or on a dead socket does not care
  that its stdout went away. Probed directly on this platform: after the
  deadline fired and the task was brutal-killed, `ps` still showed the child.

  `file_grep`'s sibling fix states the opposite in a comment
  (`file_grep/handler.ex`, "closing a Port kills the OS process it owns"). That
  claim is wrong, and the wedged `rg` it describes outlives its deadline too.
  Reaping needs the child's os_pid, which `System.cmd/3` does not expose —
  `OS.ProcessGroup` (`spawn_plan/2` + `terminate_group/2`) is the mechanism, and
  wiring it in means moving both this and `file_grep` off `System.cmd/3` and
  onto `Port.open/2`, the way `shell_execute` already runs. Deliberately not
  done here: the defect being fixed is a turn that never ends, and a leaked
  idle process is a different, smaller one that should not ride along
  unannounced on a change to twenty-two call sites.
  """
  require Logger

  # Matches `shell_execute` and `file_grep`. Generous by design: every call this
  # wraps is either local and near-instant, or remote and bounded by its own
  # connect timeout. Anything that reaches 120s is wedged, not slow.
  @default_timeout_ms 120_000

  @typedoc """
  `{:ok, output, exit_status}` when the process ran to completion — a non-zero
  status is a RESULT, not a failure of this wrapper, and is passed through.
  `{:timeout, message}` when the deadline fired: the process was killed and
  nothing was learned.
  """
  @type result :: {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}

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
    * every other option is forwarded to `System.cmd/3` unchanged.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(exe, args, opts \\ []) when is_binary(exe) and is_list(args) do
    {label, opts} = Keyword.pop(opts, :label, exe)
    {target, opts} = Keyword.pop(opts, :target)
    {timeout, cmd_opts} = Keyword.pop(opts, :timeout_ms, timeout_ms())

    cmd_opts = Keyword.put_new(cmd_opts, :stderr_to_stdout, true)

    task =
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
        System.cmd(exe, args, cmd_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} ->
        {:ok, output, status}

      # The deadline fired. Reported as ITSELF — never folded into an empty
      # `{:ok, "", 0}`, which is what every caller's error path would otherwise
      # turn it into, and which is indistinguishable from a command that
      # genuinely produced no output.
      nil ->
        {:timeout, expiry_message(label, target, timeout)}

      # The task died (binary missing, exec permission, bad interpreter). A
      # different fault from a hang, and not this module's to describe.
      {:exit, reason} ->
        Logger.debug("[BoundedCmd] #{label} exited: #{inspect(reason)}")
        {:ok, "", 1}
    end
  rescue
    e ->
      Logger.debug("[BoundedCmd] #{exe} could not be spawned: #{inspect(e)}")
      {:ok, "", 1}
  end

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
