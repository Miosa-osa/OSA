defmodule OptimalSystemAgent.OS.ProcessGroup do
  @moduledoc """
  Spawn OS children into their own process group, and reap that whole group.

  `kill <pid>` signals ONE process. A timed-out `npm run dev`, `docker run`, or
  `mix phx.server` leaves every descendant alive holding ports, file handles and
  memory, because the signal never reached them — only the wrapper shell died.

  The fix is the POSIX one: make the child a process-group leader (`setsid`) and
  signal the negative pgid so the kernel delivers to the whole group.

  This module is the shared implementation of the pattern first written inline in
  `OptimalSystemAgent.MCP.Transport.Stdio`; the safety guard is carried over
  unchanged and is the important part:

    * `killpg_safe?/1` refuses pgid <= 1 (which would signal init, or with 0 the
      CALLER'S OWN GROUP — i.e. SIGKILL the entire BEAM and anything sharing its
      group, up to the user's login session).
    * it also refuses this node's own pgid explicitly.

  Never call `System.cmd("kill", [..., "-0"])` or pass an unresolved pgid.
  """

  require Logger

  @typedoc "Result of `spawn_opts/2`: what to hand `Port.open/2` plus whether the group can be reaped."
  @type spawn_plan :: %{exe: String.t(), args: [String.t()], group?: boolean()}

  @doc """
  Build the `{executable, args}` for a group-leader spawn of `exe` + `args`.

  When `setsid` is available the command becomes `setsid -w <exe> <args...>`,
  which puts the real command in a fresh session/process group. `-w` makes
  `setsid` wait, so the port's exit status is still the command's exit status
  and the port's `os_pid` stays alive long enough to resolve the group id.

  When `setsid` is missing (Windows, minimal containers) the plan is the
  unwrapped command with `group?: false`, and callers fall back to
  single-pid/`taskkill` behavior.
  """
  @spec spawn_plan(String.t(), [String.t()]) :: spawn_plan()
  def spawn_plan(exe, args) when is_binary(exe) and is_list(args) do
    case :os.type() do
      {:win32, _} ->
        %{exe: exe, args: args, group?: false}

      _ ->
        case System.find_executable("setsid") do
          nil -> %{exe: exe, args: args, group?: false}
          setsid -> %{exe: setsid, args: ["-w", exe | args], group?: true}
        end
    end
  end

  @doc """
  Resolve the process-group id of the command running under a `setsid -w`
  wrapper whose pid is `wrapper_os_pid`.

  The wrapper's sole child IS the group leader, so its pid equals its pgid; we
  still read `ps -o pgid=` rather than assuming, so a shell that re-execs or an
  unexpected intermediate cannot make us signal the wrong group.

  Returns `nil` when the group cannot be determined — callers must then fall
  back to single-pid kill rather than guessing.
  """
  @spec resolve_pgid(pos_integer() | nil) :: pos_integer() | nil
  def resolve_pgid(nil), do: nil

  def resolve_pgid(wrapper_os_pid) when is_integer(wrapper_os_pid) do
    with [child | _] <- children_of(wrapper_os_pid),
         {out, 0} <- System.cmd("ps", ["-o", "pgid=", "-p", child], stderr_to_stdout: true),
         {pgid, _} <- Integer.parse(String.trim(out)),
         true <- pgid > 1 do
      pgid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  The process-group id THIS pid belongs to.

  `resolve_pgid/1` is for a `setsid -w` WRAPPER pid and deliberately looks one
  level down at the wrapper's child. Use `pgid_of/1` when you already hold the
  group leader itself — e.g. a pid adopted from another spawner, where there is
  no wrapper to look through.

  Returns `nil` when it cannot be read. Callers must still route the result
  through `killpg_safe?/1`: a pid that was never `setsid`-ed reports the
  BEAM's own group, and signalling that would kill the agent.
  """
  @spec pgid_of(pos_integer() | nil) :: pos_integer() | nil
  def pgid_of(nil), do: nil

  def pgid_of(os_pid) when is_integer(os_pid) and os_pid > 1 do
    with {out, 0} <-
           System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ),
         {pgid, _} <- Integer.parse(String.trim(out)),
         true <- pgid > 1 do
      pgid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def pgid_of(_), do: nil

  @doc """
  The pid of the group LEADER running under a `setsid -w` wrapper — i.e. the
  actual command, not the wrapper.

  Callers that must hand a single pid to code which only knows how to
  `kill <pid>` should hand it this, never the wrapper pid: killing the wrapper
  leaves the command itself running.

  Returns `nil` when it cannot be determined.
  """
  @spec leader_pid(pos_integer() | nil) :: pos_integer() | nil
  def leader_pid(nil), do: nil

  def leader_pid(wrapper_os_pid) when is_integer(wrapper_os_pid) do
    case children_of(wrapper_os_pid) do
      [child | _] ->
        case Integer.parse(child) do
          {pid, _} when pid > 1 -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  `false` for any pgid it would be catastrophic to signal.

  Refuses:

    * `pgid <= 1` — 0 means "my own process group" to `killpg(2)`, and 1 is
      init. Either would take down the BEAM and possibly the login session.
    * this node's own process group.
  """
  @spec killpg_safe?(term()) :: boolean()
  def killpg_safe?(pgid) when is_integer(pgid) and pgid > 1 do
    case own_pgid() do
      nil -> false
      own -> pgid != own
    end
  end

  def killpg_safe?(_), do: false

  @doc """
  This BEAM's own process-group id, or `nil` if it cannot be read.

  `nil` is treated as unsafe by `killpg_safe?/1`: if we cannot prove a group is
  not ours, we do not signal it.
  """
  @spec own_pgid() :: pos_integer() | nil
  def own_pgid do
    self_pid = :os.getpid() |> List.to_string()

    with {out, 0} <- System.cmd("ps", ["-o", "pgid=", "-p", self_pid], stderr_to_stdout: true),
         {pgid, _} <- Integer.parse(String.trim(out)) do
      pgid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  Signal a whole process group by pgid, guarded by `killpg_safe?/1`.

  Returns `:ok` when the signal was sent, `{:error, :unsafe_pgid}` when the
  guard refused. `signal` is a signal NAME (`"TERM"`, `"KILL"`).
  """
  @spec signal_group(term(), String.t()) :: :ok | {:error, :unsafe_pgid}
  def signal_group(pgid, signal) when is_binary(signal) do
    if killpg_safe?(pgid) do
      _ = System.cmd("kill", ["-s", signal, "--", "-#{pgid}"], stderr_to_stdout: true)
      :ok
    else
      {:error, :unsafe_pgid}
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Terminate a process group: SIGTERM, a grace window so the tree can flush and
  clean up, then SIGKILL for whatever ignored it.

  The grace window is the whole point — the previous code sent TERM and KILL
  back to back, which is functionally just a KILL and gives no handler a chance
  to run.
  """
  @spec terminate_group(term(), non_neg_integer()) :: :ok | {:error, :unsafe_pgid}
  def terminate_group(pgid, grace_ms \\ default_grace_ms()) do
    case signal_group(pgid, "TERM") do
      :ok ->
        wait_for_group_exit(pgid, grace_ms)
        _ = signal_group(pgid, "KILL")
        :ok

      {:error, :unsafe_pgid} = err ->
        err
    end
  end

  @doc """
  Terminate a single OS process: SIGTERM, grace, SIGKILL.

  The fallback for when no process group could be established. Still better
  than the old back-to-back TERM/KILL because the process gets its grace window.
  """
  @spec terminate_pid(pos_integer(), non_neg_integer()) :: :ok
  def terminate_pid(os_pid, grace_ms \\ default_grace_ms()) when is_integer(os_pid) do
    if os_pid > 1 do
      _ = System.cmd("kill", ["-s", "TERM", to_string(os_pid)], stderr_to_stdout: true)
      wait_for_pid_exit(os_pid, grace_ms)
      _ = System.cmd("kill", ["-s", "KILL", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Grace period between SIGTERM and SIGKILL, in milliseconds."
  @spec default_grace_ms() :: non_neg_integer()
  def default_grace_ms do
    Application.get_env(:optimal_system_agent, :kill_grace_ms, 2_000)
  end

  @doc """
  `true` when any process still belongs to `pgid`.
  """
  @spec group_alive?(pos_integer()) :: boolean()
  def group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    case System.cmd("ps", ["-o", "pid=", "-g", to_string(pgid)], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def group_alive?(_), do: false

  @doc "`true` when `os_pid` is still running."
  @spec pid_alive?(pos_integer()) :: boolean()
  def pid_alive?(os_pid) when is_integer(os_pid) and os_pid > 1 do
    match?(
      {_, 0},
      System.cmd("ps", ["-o", "pid=", "-p", to_string(os_pid)], stderr_to_stdout: true)
    )
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def pid_alive?(_), do: false

  # ── Private ──────────────────────────────────────────────────────────

  defp children_of(os_pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  rescue
    e ->
      Logger.warning(
        "[ProcessGroup] children_of(#{os_pid}) failed (pgrep unavailable?): #{Exception.message(e)}"
      )

      []
  catch
    _, _ -> []
  end

  # Poll instead of a flat sleep so a well-behaved tree that exits on SIGTERM
  # does not stall the caller for the whole grace window.
  defp wait_for_group_exit(pgid, grace_ms),
    do: poll_until(grace_ms, fn -> not group_alive?(pgid) end)

  defp wait_for_pid_exit(os_pid, grace_ms),
    do: poll_until(grace_ms, fn -> not pid_alive?(os_pid) end)

  defp poll_until(budget_ms, _fun) when budget_ms <= 0, do: :ok

  defp poll_until(budget_ms, fun) do
    step = min(100, budget_ms)

    if fun.() do
      :ok
    else
      Process.sleep(step)
      poll_until(budget_ms - step, fun)
    end
  end
end
