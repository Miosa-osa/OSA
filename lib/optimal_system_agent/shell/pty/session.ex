defmodule OptimalSystemAgent.Shell.Pty.Session do
  @moduledoc """
  A single interactive PTY session — the Elixir complement to
  `shell_execute`, which redirects stdin from `/dev/null` and so cannot drive
  programs that REQUIRE a real tty (vim, REPLs, `ssh`/installer prompts, …).

  ## PTY allocation (Linux / this box)

  Elixir/BEAM has no built-in pty. We allocate one with util-linux `script`:

      script -q -f -e -c "stty rows R cols C; <cmd>" /dev/null

  `script` forks the command with a freshly-allocated pseudo-terminal as its
  controlling tty (verified: the child sees `/dev/pts/N`, `isatty(0)` is true).
  `-f` flushes after every write (real-time output), `-e` makes `script`'s exit
  code the child's, and `/dev/null` discards the typescript file. We open it as
  an Erlang `Port` (`:spawn_executable`); writing to the port reaches the child's
  stdin through the pty master, and the child's output arrives as `{:data, _}`.

  Because `script` owns the pty master fd (not us), we set the initial window
  size with an `stty` prefix but CANNOT change the kernel window size after
  spawn — see `resize/3`.

  ## Model

  Raw output is fed into a pragmatic `Screen` grid (see
  `OptimalSystemAgent.Shell.Pty.Screen`) plus scrollback. A monotonic
  `generation` counter is bumped on every feed and on resize; event-driven
  `wait/3` blocks on generation changes instead of busy-polling — a direct port
  of grok's `ptyctl` watch-generation design.
  """

  use GenServer, restart: :temporary

  require Logger

  alias OptimalSystemAgent.Shell.Pty.{Keys, Screen}

  @raw_tail_cap 4_096
  # Keep a finished session pollable for a while before it self-retires.
  @default_linger_ms 600_000

  defstruct [
    :id,
    :name,
    :command,
    :cwd,
    :port,
    :os_pid,
    :screen,
    :started_at,
    :finished_at,
    :exit_code,
    cols: 80,
    rows: 24,
    generation: 0,
    alive: true,
    raw_tail: "",
    last_activity_mono: 0,
    linger_ms: @default_linger_ms,
    # ref => waiter map
    waiters: %{}
  ]

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:via])
  end

  @doc "Send raw bytes to the pty (child stdin)."
  @spec send_bytes(pid(), binary()) :: :ok | {:error, term()}
  def send_bytes(pid, bytes), do: GenServer.call(pid, {:send_bytes, bytes})

  @doc "Send keys in vim notation (`\"<C-c>\"`, `\"hello<CR>\"`)."
  @spec send_keys(pid(), String.t()) :: :ok | {:error, term()}
  def send_keys(pid, notation), do: send_bytes(pid, Keys.parse(notation))

  @doc "Current screen as plain text."
  @spec screen(pid()) :: String.t()
  def screen(pid), do: GenServer.call(pid, :screen)

  @doc "1-based cursor position `%{row:, col:}`."
  @spec cursor(pid()) :: map()
  def cursor(pid), do: GenServer.call(pid, :cursor)

  @doc "Scrollback lines (oldest first); `count` limits to the most recent N."
  @spec scrollback(pid(), non_neg_integer() | :all) :: [String.t()]
  def scrollback(pid, count \\ :all), do: GenServer.call(pid, {:scrollback, count})

  @doc "Lifecycle/status snapshot."
  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @doc """
  Block until `condition` is met or `timeout_ms` elapses. Event-driven.

  `condition`:
    * `{:text, needle}`   — substring appears on screen
    * `{:regex, %Regex{}}`— regex matches the screen text
    * `:gone`             — the child process exited
    * `{:stable_ms, n}`   — no grid activity for `n` ms

  Returns an outcome map `%{matched:, elapsed_ms:, ended:, screen:, cursor:, raw_tail:}`.
  """
  @spec wait(pid(), tuple() | :gone, non_neg_integer()) :: map()
  def wait(pid, condition, timeout_ms) do
    GenServer.call(pid, {:wait, condition, timeout_ms}, timeout_ms + 5_000)
  end

  @doc "Resize the emulator grid (see resize/3 caveat about the kernel pty)."
  @spec resize(pid(), pos_integer(), pos_integer()) :: :ok
  def resize(pid, cols, rows), do: GenServer.call(pid, {:resize, cols, rows})

  @doc "Kill the child process and stop the session."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.call(pid, :stop)

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    command = Keyword.fetch!(opts, :command)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    cwd = Keyword.get(opts, :cwd) || default_cwd()
    env = Keyword.get(opts, :env, [])
    name = Keyword.get(opts, :name)

    # Register the human-friendly name (if any) as a secondary registry key so
    # the manager can resolve id OR name to this pid.
    if is_binary(name) and name != "" do
      Registry.register(OptimalSystemAgent.Shell.Pty.Registry, {:name, name}, id)
    end

    case open_port(command, cols, rows, cwd, env) do
      {:ok, port, os_pid} ->
        state = %__MODULE__{
          id: id,
          name: name,
          command: command,
          cwd: cwd,
          port: port,
          os_pid: os_pid,
          screen: Screen.new(cols, rows),
          cols: cols,
          rows: rows,
          started_at: DateTime.utc_now(),
          last_activity_mono: now_ms()
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  # PTY allocation. `allocator/0` picks the available wrapper; today that is
  # util-linux `script`. Graceful failure if none is present.
  defp open_port(command, cols, rows, cwd, env) do
    case allocator() do
      {:ok, exe, wrap} ->
        inner = "stty rows #{rows} cols #{cols} 2>/dev/null; #{command}"
        args = wrap.(inner)

        port_opts = [
          :binary,
          :exit_status,
          :hide,
          {:args, args},
          {:cd, cwd},
          {:env, normalize_env(env)}
        ]

        try do
          port = Port.open({:spawn_executable, exe}, port_opts)

          os_pid =
            case Port.info(port, :os_pid) do
              {:os_pid, pid} -> pid
              _ -> nil
            end

          {:ok, port, os_pid}
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Resolve the pty allocator available on this host.

  Returns `{:ok, executable, wrap_fun}` where `wrap_fun.(inner_cmd)` yields the
  argv (excluding the executable), or `{:error, :no_pty_allocator}`.
  """
  @spec allocator() :: {:ok, String.t(), (String.t() -> [String.t()])} | {:error, atom()}
  def allocator do
    case System.find_executable("script") do
      nil ->
        {:error, :no_pty_allocator}

      script ->
        {:ok, script, fn inner -> ["-q", "-f", "-e", "-c", inner, "/dev/null"] end}
    end
  end

  @impl true
  def handle_call({:send_bytes, _bytes}, _from, %{alive: false} = state) do
    {:reply, {:error, :not_alive}, state}
  end

  def handle_call({:send_bytes, bytes}, _from, state) do
    Port.command(state.port, bytes)
    {:reply, :ok, state}
  rescue
    e -> {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call(:screen, _from, state), do: {:reply, Screen.text(state.screen), state}
  def handle_call(:cursor, _from, state), do: {:reply, Screen.cursor(state.screen), state}

  def handle_call({:scrollback, count}, _from, state),
    do: {:reply, Screen.scrollback(state.screen, count), state}

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:resize, cols, rows}, _from, state) do
    # NOTE: `script` owns the pty master fd, so we cannot issue TIOCSWINSZ to
    # change the CHILD's kernel window size after spawn. This reshapes the
    # emulator grid only (so `screen/0` reflows) and bumps the generation so
    # in-flight `stable_ms`/text waits re-check. A running full-screen app will
    # still believe the tty is the ORIGINAL size until it exits.
    screen = Screen.resize(state.screen, cols, rows)
    state = %{state | screen: screen, cols: cols, rows: rows}
    state = bump_generation(state)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    kill_child(state.os_pid)
    state = finalize(state, state.exit_code || :killed)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:wait, condition, timeout_ms}, from, state) do
    with {:ok, condition} <- normalize_condition(condition) do
      register_waiter(state, from, condition, timeout_ms)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ── Port lifecycle ─────────────────────────────────────────────────────

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    screen = Screen.feed(state.screen, data)
    raw_tail = tail(state.raw_tail <> data, @raw_tail_cap)

    state =
      %{state | screen: screen, raw_tail: raw_tail, last_activity_mono: now_ms()}
      |> bump_generation()

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = finalize(state, code)
    # Let the session linger so a post-exit read/wait still works, then retire.
    Process.send_after(self(), :retire, state.linger_ms)
    {:noreply, state}
  end

  # Overall wait deadline.
  def handle_info({:wait_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        {:noreply, state}

      {waiter, waiters} ->
        GenServer.reply(waiter.from, timeout_outcome(state, waiter, false))
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # A `stable_ms` window elapsed — match iff no activity since it was armed.
  def handle_info({:stable_tick, ref}, state) do
    case Map.get(state.waiters, ref) do
      %{condition: {:stable_ms, window}} = waiter ->
        if now_ms() - state.last_activity_mono >= window do
          GenServer.reply(waiter.from, matched_outcome(state, waiter))
          cancel_timers(waiter)
          {:noreply, %{state | waiters: Map.delete(state.waiters, ref)}}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:retire, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Waiter machinery ───────────────────────────────────────────────────

  defp register_waiter(state, from, condition, timeout_ms) do
    waiter = %{
      from: from,
      condition: condition,
      started_mono: now_ms(),
      deadline_ref: Process.send_after(self(), {:wait_timeout, make_ref_key(from)}, timeout_ms),
      stable_ref: nil
    }

    # Fast-path: for non-stable conditions, resolve immediately if already met
    # (and don't wait past a dead session).
    case immediate_check(state, condition) do
      {:matched, true} ->
        Process.cancel_timer(waiter.deadline_ref)
        {:reply, matched_outcome(state, waiter), state}

      {:ended, true} ->
        Process.cancel_timer(waiter.deadline_ref)
        {:reply, timeout_outcome(state, waiter, true), state}

      :pending ->
        ref = make_ref_key(from)

        waiter =
          case condition do
            {:stable_ms, window} ->
              %{waiter | stable_ref: Process.send_after(self(), {:stable_tick, ref}, window)}

            _ ->
              waiter
          end

        {:noreply, %{state | waiters: Map.put(state.waiters, ref, waiter)}}
    end
  end

  # Re-check all pending text/regex/gone waiters after a generation bump.
  defp evaluate_waiters(state) do
    text = Screen.text(state.screen)

    Enum.reduce(state.waiters, state, fn {ref, waiter}, acc ->
      case satisfied?(waiter.condition, text, state.alive) do
        true ->
          GenServer.reply(waiter.from, matched_outcome(acc, waiter))
          cancel_timers(waiter)
          %{acc | waiters: Map.delete(acc.waiters, ref)}

        false ->
          maybe_rearm_stable(acc, ref, waiter)
      end
    end)
  end

  # On activity, restart each stable window (matches grok: a resize/feed
  # restarts the stability window).
  defp maybe_rearm_stable(state, ref, %{condition: {:stable_ms, window}} = waiter) do
    cancel_stable(waiter)
    new_ref = Process.send_after(self(), {:stable_tick, ref}, window)
    put_in(state.waiters[ref], %{waiter | stable_ref: new_ref})
  end

  defp maybe_rearm_stable(state, _ref, _waiter), do: state

  defp satisfied?({:text, needle}, text, _alive), do: String.contains?(text, needle)
  defp satisfied?({:regex, re}, text, _alive), do: Regex.match?(re, text)
  defp satisfied?(:gone, _text, alive), do: not alive
  # stable_ms is timer-driven, never satisfied by a screen check.
  defp satisfied?({:stable_ms, _}, _text, _alive), do: false

  defp immediate_check(_state, {:stable_ms, _}), do: :pending

  defp immediate_check(state, condition) do
    text = Screen.text(state.screen)

    cond do
      satisfied?(condition, text, state.alive) -> {:matched, true}
      # Session already over and the condition can never be met → fail fast.
      not state.alive and condition != :gone -> {:ended, true}
      true -> :pending
    end
  end

  # When the child exits, resolve every outstanding waiter: `:gone` matches;
  # others get one last screen check, else a fail-fast `ended` outcome.
  defp resolve_waiters_on_exit(state) do
    text = Screen.text(state.screen)

    Enum.each(state.waiters, fn {_ref, waiter} ->
      cancel_timers(waiter)

      outcome =
        if satisfied?(waiter.condition, text, false),
          do: matched_outcome(state, waiter),
          else: timeout_outcome(state, waiter, true)

      GenServer.reply(waiter.from, outcome)
    end)

    %{state | waiters: %{}}
  end

  # ── Outcomes ───────────────────────────────────────────────────────────

  defp matched_outcome(state, waiter) do
    base_outcome(state, waiter, true, not state.alive)
  end

  defp timeout_outcome(state, waiter, ended) do
    base_outcome(state, waiter, false, ended)
  end

  defp base_outcome(state, waiter, matched, ended) do
    %{
      matched: matched,
      ended: ended,
      elapsed_ms: now_ms() - waiter.started_mono,
      generation: state.generation,
      screen: Screen.text(state.screen),
      cursor: Screen.cursor(state.screen),
      raw_tail: state.raw_tail
    }
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp bump_generation(state) do
    %{state | generation: state.generation + 1} |> evaluate_waiters()
  end

  defp finalize(%{alive: false} = state, _code), do: state

  defp finalize(state, code) do
    exit_code = if is_integer(code), do: code, else: state.exit_code

    state = %{
      state
      | alive: false,
        exit_code: exit_code,
        finished_at: state.finished_at || DateTime.utc_now(),
        generation: state.generation + 1
    }

    resolve_waiters_on_exit(state)
  end

  defp status_map(state) do
    %{
      id: state.id,
      name: state.name,
      command: state.command,
      cwd: state.cwd,
      os_pid: state.os_pid,
      alive: state.alive,
      exit_code: state.exit_code,
      cols: state.cols,
      rows: state.rows,
      generation: state.generation,
      scrollback_lines: length(state.screen.scrollback),
      started_at: state.started_at,
      finished_at: state.finished_at
    }
  end

  defp normalize_condition({:text, s}) when is_binary(s), do: {:ok, {:text, s}}
  defp normalize_condition(:gone), do: {:ok, :gone}
  defp normalize_condition({:stable_ms, n}) when is_integer(n) and n >= 0, do: {:ok, {:stable_ms, n}}
  defp normalize_condition({:regex, %Regex{} = re}), do: {:ok, {:regex, re}}

  defp normalize_condition({:regex, pattern}) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, {:regex, re}}
      {:error, {reason, at}} -> {:error, "invalid regex at #{at}: #{reason}"}
    end
  end

  defp normalize_condition(other), do: {:error, "unsupported wait condition: #{inspect(other)}"}

  defp cancel_timers(waiter) do
    if waiter.deadline_ref, do: Process.cancel_timer(waiter.deadline_ref)
    cancel_stable(waiter)
  end

  defp cancel_stable(%{stable_ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_stable(_), do: :ok

  # A stable key per waiter `from` — the from tuple is unique per in-flight call.
  defp make_ref_key(from), do: from

  defp kill_child(nil), do: :ok

  defp kill_child(os_pid) do
    _ = System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    _ = System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} -> {to_charlist(k), to_charlist(v)}
      other -> other
    end)
  end

  defp normalize_env(_), do: []

  defp default_cwd do
    case OptimalSystemAgent.Workspace.Cwd.get() do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.tmp_dir!() || "/tmp"
    end
  rescue
    _ -> System.tmp_dir!() || "/tmp"
  end

  defp tail(bin, cap) when byte_size(bin) <= cap, do: bin
  defp tail(bin, cap), do: binary_part(bin, byte_size(bin) - cap, cap)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
