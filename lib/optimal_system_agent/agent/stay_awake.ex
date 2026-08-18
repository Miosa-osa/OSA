defmodule OptimalSystemAgent.Agent.StayAwake do
  @moduledoc """
  Keeps the machine awake while a turn is in flight.

  ## Why this is backend-side

  The TUI already holds an OS sleep inhibitor (`notification/inhibit.rs`), but
  the TUI is not what does the work. OSA runs as a background daemon: the
  operator starts a long task, detaches the terminal (or closes the laptop's
  session, or simply stops touching the keyboard), and the daemon carries on.
  With the inhibitor living only in the TUI, an unattended overnight run dies
  the moment the machine idles out — and it dies silently, mid-turn, which
  looks exactly like the agent "just stopping" for no reason.

  ## Lifetime

  Reference-counted across sessions: the OS inhibitor starts when the first
  holder acquires and stops when the last one releases, so concurrent sessions
  do not fight over it. Holders are monitored, so a loop process that crashes
  releases its hold automatically rather than pinning the machine awake until
  reboot — the failure mode that would make this feature worse than not having
  it.

  ## Platform

    * macOS — `caffeinate -i -m -s`
    * Linux — `systemd-inhibit --what=idle:sleep --mode=block … sleep infinity`
    * anything else — no-op, and `acquire/1` still succeeds. A missing inhibitor
      must never fail a turn.

  The child process is spawned as a port and killed by OS pid on release. It is
  also tied to the VM: if the BEAM dies, the port closes and the inhibitor goes
  with it, so a crash cannot leave `caffeinate` running forever.
  """
  use GenServer

  require Logger

  @name __MODULE__

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Hold the machine awake on behalf of `session_id`.

  Safe to call repeatedly for the same session — a session holds at most one
  reference, so an extra acquire cannot outlive its matching release.
  Never raises: if the server is not running, this is a no-op.
  """
  @spec acquire(String.t() | nil) :: :ok
  def acquire(session_id) do
    GenServer.cast(@name, {:acquire, session_id, self()})
  catch
    :exit, _ -> :ok
  end

  @doc "Release this session's hold. Idempotent."
  @spec release(String.t() | nil) :: :ok
  def release(session_id) do
    GenServer.cast(@name, {:release, session_id})
  catch
    :exit, _ -> :ok
  end

  @doc false
  def held? do
    GenServer.call(@name, :held?)
  catch
    :exit, _ -> false
  end

  @doc false
  def holders do
    GenServer.call(@name, :holders)
  catch
    :exit, _ -> []
  end

  # ── Server ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{holders: %{}, monitors: %{}, port: nil, os_pid: nil}}
  end

  @impl true
  def handle_cast({:acquire, session_id, pid}, state) do
    key = key_for(session_id, pid)

    if Map.has_key?(state.holders, key) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)

      state
      |> put_in([:holders, key], ref)
      |> put_in([:monitors, ref], key)
      |> ensure_running()
      |> then(&{:noreply, &1})
    end
  end

  @impl true
  def handle_cast({:release, session_id}, state) do
    {:noreply, drop_matching(state, fn key -> match?({^session_id, _}, key) end)}
  end

  @impl true
  def handle_call(:held?, _from, state), do: {:reply, state.port != nil, state}

  @impl true
  def handle_call(:holders, _from, state), do: {:reply, Map.keys(state.holders), state}

  # A holder died without releasing. Drop its hold rather than pinning the
  # machine awake for the rest of the day.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, key} -> {:noreply, drop_matching(state, &(&1 == key))}
      :error -> {:noreply, state}
    end
  end

  # The inhibitor exited on its own (killed externally, systemd restart, …).
  # Forget the handle; the next acquire starts a fresh one.
  @impl true
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_inhibitor(state)
    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp key_for(session_id, pid), do: {session_id, pid}

  defp drop_matching(state, pred) do
    {dropped, kept} = Enum.split_with(state.holders, fn {key, _ref} -> pred.(key) end)

    Enum.each(dropped, fn {_key, ref} -> Process.demonitor(ref, [:flush]) end)

    monitors =
      Enum.reduce(dropped, state.monitors, fn {_key, ref}, acc -> Map.delete(acc, ref) end)

    %{state | holders: Map.new(kept), monitors: monitors}
    |> maybe_stop()
  end

  defp ensure_running(%{port: port} = state) when port != nil, do: state

  defp ensure_running(state) do
    case inhibitor_command() do
      nil ->
        # Unsupported platform, or the tool is not installed. Not an error: the
        # turn proceeds, it just is not protected from an idle sleep.
        state

      {exe, args} ->
        try do
          port =
            Port.open({:spawn_executable, exe}, [
              :binary,
              :exit_status,
              {:args, args}
            ])

          os_pid = port |> Port.info(:os_pid) |> elem(1)
          Logger.info("[StayAwake] holding the machine awake (#{Path.basename(exe)})")
          %{state | port: port, os_pid: os_pid}
        rescue
          e ->
            Logger.warning("[StayAwake] could not start inhibitor: #{Exception.message(e)}")
            state
        end
    end
  end

  defp maybe_stop(%{holders: holders} = state) when map_size(holders) == 0 do
    stop_inhibitor(state)
    %{state | port: nil, os_pid: nil}
  end

  defp maybe_stop(state), do: state

  defp stop_inhibitor(%{port: nil}), do: :ok

  defp stop_inhibitor(%{port: port, os_pid: os_pid}) do
    # Closing the port alone is not enough: `caffeinate` ignores a closed stdin
    # and would keep the machine awake indefinitely. Kill the OS process too.
    if is_integer(os_pid), do: System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    if is_port(port), do: Port.close(port)
    Logger.info("[StayAwake] released")
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def inhibitor_command do
    case Application.get_env(:optimal_system_agent, :stay_awake_command, :auto) do
      :auto -> detect_command()
      :disabled -> nil
      {_exe, _args} = explicit -> explicit
    end
  end

  defp detect_command do
    case :os.type() do
      {:unix, :darwin} ->
        # -i idle, -m disk, -s system sleep while on AC.
        with exe when is_binary(exe) <- System.find_executable("caffeinate") do
          {exe, ["-i", "-m", "-s"]}
        else
          _ -> nil
        end

      {:unix, _} ->
        with exe when is_binary(exe) <- System.find_executable("systemd-inhibit") do
          {exe,
           [
             "--what=idle:sleep",
             "--mode=block",
             "--who=OSA",
             "--why=agent turn in flight",
             "sleep",
             "infinity"
           ]}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
