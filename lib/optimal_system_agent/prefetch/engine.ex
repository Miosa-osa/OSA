defmodule OptimalSystemAgent.Prefetch.Engine do
  @moduledoc """
  Speculative prefetch — runs ahead of the model's own tool calls.

  While a turn is still streaming, this fires read-only tool calls the model
  is likely to make next — for files it just named in its own streamed text,
  and for the siblings/test file of whatever it just edited — and stashes the
  results in `Prefetch.Cache`. When the model's real call arrives,
  `Agent.Loop.ToolExecutor` checks the cache first; a hit skips the real
  dispatch and returns instantly. `Cache` re-validates every hit against the
  filesystem before serving it — see its moduledoc — so a change from ANY
  source (another tool call, the user's editor, `git checkout`, a formatter)
  is never served stale.

  Never visible to the model unless it actually asks: a candidate that never
  gets a matching real call just expires (TTL) or gets evicted (row cap) —
  nothing about a fired-but-unused prefetch reaches the transcript, a tool
  message, or a log line above `:debug`.

  ## Bounding

  Two independent caps, both best-effort (a prefetch that cannot get a slot is
  dropped, never queued):

    * `@max_concurrent` — global in-flight ceiling across every session.
    * per-candidate dedup — the same `{tool, args}` fingerprint is never fired
      twice while a fetch for it is already running.

  Every fired task also carries its own hard timeout (`@task_timeout_ms`), so
  a wedged read cannot hold a slot forever.

  ## Observability

  Every hit/miss/fire/invalidation increments this session's turn counters.
  `end_turn/1` (called once per turn, from `Observability.turn_end/2`) emits
  one `[:osa, :prefetch, :turn]` telemetry event with the turn's hit rate and
  estimated time saved, then resets the counters for the next turn.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Prefetch.Cache
  alias OptimalSystemAgent.Prefetch.Heuristics
  alias OptimalSystemAgent.Prefetch.ReadOnlyTools
  alias OptimalSystemAgent.Workspace.Cwd

  @inflight_table :osa_prefetch_inflight

  @max_concurrent 4
  @task_timeout_ms 4_000

  # Scan the accumulated streamed text at most this often per session, and
  # only once it has grown by at least this many bytes since the last scan —
  # a prefetch fired on every few-byte delta would spend more CPU deciding not
  # to fire than the tool calls it is trying to save.
  @text_scan_min_interval_ms 400
  @text_scan_min_growth_bytes 40

  defstruct sessions: %{}, inflight: 0

  # ── Client API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Direct, non-blocking cache lookup for `tool_name(args)`. Called by
  `Agent.Loop.ToolExecutor` before every real dispatch. Bypasses the
  GenServer entirely (an ETS read), so this never adds latency to a cache
  miss — the common case.
  """
  @spec lookup(String.t(), map()) :: {:hit, String.t()} | :miss
  def lookup(tool_name, args) do
    key = Cache.fingerprint(tool_name, args)

    case Cache.get(key) do
      {:hit, result, duration_ms} ->
        session_id = session_of(args)
        record(session_id, :hit, duration_ms)
        {:hit, result}

      :miss ->
        record(session_of(args), :miss, 0)
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  New text has streamed in for `session_id`. Throttled internally — most
  calls are no-ops. Extracts file-path-looking tokens from the FULL
  accumulated text (not just this delta, since a path can straddle two
  chunks) and fires `file_read` prefetches for the ones that exist on disk.
  """
  @spec observe_text(String.t() | nil, String.t()) :: :ok
  def observe_text(session_id, accumulated_text)
      when is_binary(session_id) and session_id != "" and is_binary(accumulated_text) do
    GenServer.cast(__MODULE__, {:observe_text, session_id, accumulated_text})
  rescue
    _ -> :ok
  end

  def observe_text(_session_id, _text), do: :ok

  @doc """
  A tool call just finished. On a successful write-shaped call, invalidates
  whatever it touched and fires the post-edit candidates (siblings, test
  file). A no-op for read-only calls and for failures (nothing changed on
  disk).
  """
  @spec observe_tool_result(String.t(), map(), boolean(), String.t() | nil) :: :ok
  def observe_tool_result(tool_name, args, success, session_id)

  def observe_tool_result(tool_name, args, true, session_id)
      when is_binary(tool_name) and is_map(args) do
    GenServer.cast(__MODULE__, {:observe_write, tool_name, args, session_id})
  rescue
    _ -> :ok
  end

  def observe_tool_result(_tool_name, _args, _success, _session_id), do: :ok

  @doc "This turn is over. Emits a telemetry summary and resets the counters."
  @spec end_turn(String.t() | nil) :: :ok
  def end_turn(session_id) when is_binary(session_id) and session_id != "" do
    GenServer.cast(__MODULE__, {:end_turn, session_id})
  rescue
    _ -> :ok
  end

  def end_turn(_session_id), do: :ok

  @doc "Current accumulated counters for `session_id`, without resetting them."
  @spec turn_stats(String.t()) :: map()
  def turn_stats(session_id) do
    GenServer.call(__MODULE__, {:turn_stats, session_id})
  catch
    :exit, _ -> empty_stats()
  end

  @doc "Forget a session's throttle/stat state (session end / `/clear`)."
  @spec forget_session(String.t()) :: :ok
  def forget_session(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:forget_session, session_id})
  rescue
    _ -> :ok
  end

  def forget_session(_), do: :ok

  # ── Server ─────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    Cache.init_tables()
    init_inflight_table()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:observe_text, session_id, text}, state) do
    session = Map.get(state.sessions, session_id, session_defaults())

    now = System.monotonic_time(:millisecond)
    grown_enough = byte_size(text) - session.last_scan_len >= @text_scan_min_growth_bytes
    time_ok = now - session.last_scan_at >= @text_scan_min_interval_ms

    state =
      if grown_enough and time_ok do
        cwd = cwd_for(session_id)
        candidates = Heuristics.candidates_from_text(text, cwd)
        state = fire_all(candidates, session_id, state)

        put_session(state, session_id, %{
          session
          | last_scan_len: byte_size(text),
            last_scan_at: now
        })
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:observe_write, tool_name, args, session_id}, state) do
    case Heuristics.classify_write(tool_name, args) do
      {:paths, paths} ->
        Enum.each(paths, &Cache.invalidate_path/1)
        state = Enum.reduce(paths, state, &fire_post_edit_candidates(&1, session_id, &2))
        {:noreply, state}

      :repo_wide ->
        Cache.invalidate_all()
        {:noreply, state}

      :none ->
        {:noreply, state}
    end
  end

  def handle_cast({:end_turn, session_id}, state) do
    session = Map.get(state.sessions, session_id, session_defaults())
    emit_turn_telemetry(session_id, session.stats)

    reset = %{session | stats: empty_stats()}
    {:noreply, put_session(state, session_id, reset)}
  end

  def handle_cast({:forget_session, session_id}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  def handle_cast({:record, session_id, kind, extra}, state) do
    session = Map.get(state.sessions, session_id, session_defaults())

    {:noreply,
     put_session(state, session_id, %{session | stats: bump(session.stats, kind, extra)})}
  end

  def handle_cast(:fire_done, state) do
    {:noreply, %{state | inflight: max(state.inflight - 1, 0)}}
  end

  @impl true
  def handle_call({:turn_stats, session_id}, _from, state) do
    session = Map.get(state.sessions, session_id, session_defaults())
    {:reply, session.stats, state}
  end

  # ── Private: firing ────────────────────────────────────────────────────

  defp fire_post_edit_candidates(path, session_id, state) do
    candidates = Heuristics.sibling_candidates(path) ++ Heuristics.test_file_candidates(path)
    fire_all(candidates, session_id, state)
  end

  defp fire_all(candidates, session_id, state) do
    Enum.reduce(candidates, state, &fire_one(&1, session_id, &2))
  end

  defp fire_one(_candidate, _session_id, %__MODULE__{inflight: n} = state)
       when n >= @max_concurrent,
       do: state

  defp fire_one(%{tool: tool, args: args} = candidate, session_id, state) do
    key = Cache.fingerprint(tool, args)

    if Cache.get(key) != :miss or not claim(key) do
      state
    else
      spawn_prefetch(candidate, key, session_id)
      state = record_local(state, session_id, :fired, 0)
      %{state | inflight: state.inflight + 1}
    end
  end

  # ONE supervised task per candidate. The timeout bound lives INSIDE it (an
  # inner `Task.async` + `Task.yield`/`Task.shutdown`) rather than in a second
  # watcher task, so the concurrency slot and the dedup claim are released
  # exactly once, on every path — normal completion, a raised exception
  # (caught by `run_and_store/6`), and a hard timeout alike. A two-task
  # version of this (a watcher racing the worker) can only free the slot on
  # whichever path it itself observes finishing first; if the worker is
  # brutal-killed by the watcher, the worker's own "I'm done" message never
  # fires, and something has to be the one that always runs. Doing the
  # bounding in the same process that holds the result is what makes that
  # true here without a second bookkeeping path.
  defp spawn_prefetch(%{tool: tool, args: args, watch: watch}, key, session_id) do
    cwd = cwd_for(session_id)
    engine = self()

    # `start_child/2`, not `async_nolink/2`: nobody ever awaits this task, and
    # `async_nolink` still expects its caller (the Engine) to consume a
    # `{ref, result}` / `{:DOWN, ref, ...}` pair when it finishes — undelivered,
    # those pile up as "unexpected message" noise in the GenServer's mailbox.
    # `start_child/2` is the actual fire-and-forget primitive: supervised
    # against crashing the caller, no completion contract to honour.
    {:ok, _pid} =
      Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
        Cwd.put_process_override(cwd)

        if is_binary(session_id) and session_id != "",
          do: Process.put(:osa_session_id, session_id)

        inner = Task.async(fn -> run_and_store(tool, args, watch, key, session_id) end)

        case Task.yield(inner, @task_timeout_ms) do
          {:ok, _} -> :ok
          {:exit, _} -> :ok
          nil -> Task.shutdown(inner, :brutal_kill)
        end

        release(key)
        GenServer.cast(engine, :fire_done)
      end)

    :ok
  end

  # The pre/post-stat protocol that makes a cached entry trustworthy: stat the
  # watched path BEFORE running the read, run it, stat again AFTER. Only when
  # the two snapshots are IDENTICAL do we know the content just read actually
  # corresponds to that exact filesystem state — if the file changed while we
  # were reading it (any source: another tool call, the user's editor, a
  # formatter, `git checkout`), the two stats differ and the result is
  # discarded, never cached. `Cache.put/5` re-checks once more immediately
  # before inserting as a last-instant guard on the read-to-store window
  # itself; every subsequent `Cache.get/1` re-validates against the filesystem
  # again, so a change landing strictly AFTER storage is caught there instead.
  defp run_and_store(tool, args, {:path, path} = watch, key, session_id) do
    started_at = System.monotonic_time(:millisecond)
    pre_stat = Cache.stat_snapshot(path)

    if pre_stat do
      case ReadOnlyTools.run(tool, args, session_id) do
        {:ok, result} ->
          post_stat = Cache.stat_snapshot(path)

          if post_stat == pre_stat do
            duration_ms = System.monotonic_time(:millisecond) - started_at
            Cache.put(key, result, watch, post_stat, duration_ms)
          else
            Logger.debug(
              "[prefetch] #{tool} #{path} changed while being read — discarding, not caching"
            )
          end

        :skip ->
          :ok
      end
    end
  rescue
    e -> Logger.debug("[prefetch] #{tool} fetch raised: #{Exception.message(e)}")
  end

  # ── Private: dedup ─────────────────────────────────────────────────────

  defp claim(key), do: :ets.insert_new(@inflight_table, {key, true})
  defp release(key), do: :ets.delete(@inflight_table, key)

  defp init_inflight_table do
    :ets.new(@inflight_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Private: stats ─────────────────────────────────────────────────────

  defp record(session_id, kind, extra) do
    GenServer.cast(__MODULE__, {:record, session_id, kind, extra})
  rescue
    _ -> :ok
  end

  defp record_local(state, session_id, kind, extra) do
    session = Map.get(state.sessions, session_id, session_defaults())
    put_session(state, session_id, %{session | stats: bump(session.stats, kind, extra)})
  end

  defp session_of(args) when is_map(args), do: args["__session_id__"] || args[:__session_id__]
  defp session_of(_), do: nil

  defp session_defaults, do: %{last_scan_len: 0, last_scan_at: 0, stats: empty_stats()}

  defp empty_stats, do: %{fired: 0, hits: 0, misses: 0, time_saved_ms: 0}

  defp bump(stats, :fired, _), do: %{stats | fired: stats.fired + 1}

  defp bump(stats, :hit, saved_ms),
    do: %{stats | hits: stats.hits + 1, time_saved_ms: stats.time_saved_ms + saved_ms}

  defp bump(stats, :miss, _), do: %{stats | misses: stats.misses + 1}

  defp put_session(state, session_id, session) when is_binary(session_id) and session_id != "" do
    %{state | sessions: Map.put(state.sessions, session_id, session)}
  end

  defp put_session(state, _session_id, _session), do: state

  defp emit_turn_telemetry(session_id, stats) do
    attempts = stats.hits + stats.misses
    hit_rate = if attempts > 0, do: stats.hits / attempts, else: nil

    :telemetry.execute(
      [:osa, :prefetch, :turn],
      %{
        fired: stats.fired,
        hits: stats.hits,
        misses: stats.misses,
        time_saved_ms: stats.time_saved_ms
      },
      %{session_id: session_id, hit_rate: hit_rate}
    )
  rescue
    _ -> :ok
  end

  defp cwd_for(session_id) do
    Cwd.session_dir(session_id) || Cwd.original_cwd()
  rescue
    _ -> File.cwd!()
  end
end
