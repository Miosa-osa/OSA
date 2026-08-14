defmodule OptimalSystemAgent.Runtime.SessionManager do
  @moduledoc """
  Runtime facade for agent session lifecycle.

  This module centralizes the thin but load-bearing glue between channel
  adapters, `SessionRegistry`, `SessionSupervisor`, and `Agent.Loop`.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @tracked_sessions_table :osa_runtime_sessions
  @default_retry_delay_ms 50

  @type session_id :: String.t()
  @type channel :: atom()

  @doc "Create and track a session without necessarily starting its loop yet."
  @spec create_session(keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(opts \\ []) do
    try do
      session_id = Keyword.get(opts, :session_id, default_session_id())
      user_id = opts |> Keyword.get(:user_id, "anonymous") |> to_string()
      channel = Keyword.get(opts, :channel, :unknown)
      created_at = DateTime.utc_now()

      metadata = %{
        session_id: session_id,
        user_id: user_id,
        channel: channel,
        working_dir: Keyword.get(opts, :working_dir),
        created_at: DateTime.to_iso8601(created_at)
      }

      track_session(session_id, metadata)
      {:ok, Map.put(metadata, :created_at_datetime, created_at)}
    rescue
      e -> {:error, e}
    end
  end

  @doc "Track a known session ID for channel-level lifecycle before a loop exists."
  @spec track_session(session_id(), map()) :: :ok
  def track_session(session_id, metadata \\ %{}) when is_binary(session_id) do
    ensure_tracked_sessions_table()

    created_at =
      Map.get_lazy(metadata, :created_at, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    :ets.insert(@tracked_sessions_table, {session_id, Map.put(metadata, :created_at, created_at)})
    :ok
  end

  @doc "Return tracked session IDs that may not currently have live loop processes."
  @spec tracked_session_ids() :: [session_id()]
  def tracked_session_ids do
    ensure_tracked_sessions_table()
    :ets.tab2list(@tracked_sessions_table) |> Enum.map(fn {id, _meta} -> id end)
  end

  @doc """
  Metadata recorded for a tracked session, or `nil` when it was never tracked.

  Carries `:created_at` (ISO8601), which is what lets a listing put the newest
  sessions first. Without it a caller can only see tracked ids in ETS order,
  which is arbitrary — so a session created a moment ago can sort behind
  hundreds of older ones and fall off the first page of its own listing.
  """
  @spec tracked_session_meta(session_id()) :: map() | nil
  def tracked_session_meta(session_id) when is_binary(session_id) do
    ensure_tracked_sessions_table()

    case :ets.lookup(@tracked_sessions_table, session_id) do
      [{^session_id, meta}] when is_map(meta) -> meta
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def tracked_session_meta(_), do: nil

  @doc "Return live session IDs registered by running loop processes."
  @spec live_session_ids() :: [session_id()]
  def live_session_ids do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  @doc "Return all known session IDs, including tracked-but-not-running sessions."
  @spec list_session_ids() :: [session_id()]
  def list_session_ids do
    Enum.uniq(live_session_ids() ++ tracked_session_ids())
  end

  @doc "True when a session is either live or tracked as created/resumable."
  @spec session_exists?(session_id()) :: boolean()
  def session_exists?(session_id) when is_binary(session_id) do
    live_session?(session_id) or tracked_session?(session_id)
  end

  def session_exists?(_), do: false

  @doc "True when a loop process is registered for this session."
  @spec live_session?(session_id()) :: boolean()
  def live_session?(session_id) when is_binary(session_id) do
    match?([{_pid, _meta}], Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id))
  rescue
    _ -> false
  end

  def live_session?(_), do: false

  @doc "True when a session was created or tracked by a runtime channel."
  @spec tracked_session?(session_id()) :: boolean()
  def tracked_session?(session_id) when is_binary(session_id) do
    ensure_tracked_sessions_table()
    :ets.member(@tracked_sessions_table, session_id)
  end

  def tracked_session?(_), do: false

  @doc """
  Ensure an agent loop exists for a session.

  Accepts `:user_id`, `:channel`, and `:retry_delay_ms`. Races where another
  caller starts the same loop are treated as success.
  """
  @spec ensure_loop(session_id(), keyword()) :: :ok | {:error, term()}
  def ensure_loop(session_id, opts \\ [])

  def ensure_loop(session_id, opts) when is_binary(session_id) do
    if live_session?(session_id) do
      # An already-live loop must still pick up a changed working_dir (e.g. a new
      # turn from a different folder) instead of staying frozen at first-turn cwd.
      maybe_update_working_dir(session_id, Keyword.get(opts, :working_dir))
      :ok
    else
      case start_loop(session_id, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          retry_delay = Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms)
          Logger.warning("[SessionManager] Loop start failed (#{inspect(reason)}), retrying once")
          Process.sleep(retry_delay)
          start_loop(session_id, opts)
      end
    end
  end

  def ensure_loop(_, _), do: {:error, :invalid_session_id}

  defp maybe_put_working_dir(opts, wd) when is_binary(wd) and wd != "",
    do: Keyword.put(opts, :working_dir, wd)

  defp maybe_put_working_dir(opts, _), do: opts

  defp maybe_put_parent(opts, parent) when is_binary(parent) and parent != "",
    do: Keyword.put(opts, :parent_session_id, parent)

  defp maybe_put_parent(opts, _), do: opts

  # Thread through optional loop opts only when explicitly provided, so a plain
  # channel session keeps Loop.init's defaults. This is what lets a full-power
  # fleet node (Agent.Fleet) pass its agent-type system prompt + tool allowlist +
  # budget cap into the spawned Loop without a bespoke start path.
  @passthrough_opts [
    :system_prompt_override,
    :allowed_tools,
    :blocked_tools,
    :role,
    :provider,
    :model,
    :max_budget_usd,
    :max_turns,
    :permission_mode
  ]

  defp put_passthrough_opts(loop_opts, opts) do
    Enum.reduce(@passthrough_opts, loop_opts, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> acc
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  # Push a changed working_dir into a live loop. Best-effort: a loop mid-turn (or
  # gone) must never make ensure_loop fail.
  defp maybe_update_working_dir(session_id, wd) when is_binary(wd) and wd != "" do
    case lookup_loop(session_id) do
      {:ok, pid, _owner} ->
        try do
          GenServer.call(pid, {:set_working_dir, wd})
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  defp maybe_update_working_dir(_session_id, _wd), do: :ok

  @doc "Compatibility arity for existing channel adapters."
  @spec ensure_loop(session_id(), String.t(), channel()) :: :ok | {:error, term()}
  def ensure_loop(session_id, user_id, channel) do
    ensure_loop(session_id, user_id: user_id, channel: channel)
  end

  @doc "Process a message synchronously through an existing loop."
  @spec process_message(session_id(), String.t(), keyword()) :: term()
  def process_message(session_id, message, opts \\ []) do
    Loop.process_message(session_id, message, opts)
  end

  @doc "Process a message in a supervised background task."
  @spec process_message_async(session_id(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def process_message_async(session_id, message, opts \\ []) do
    task_supervisor = Keyword.get(opts, :task_supervisor, OptimalSystemAgent.TaskSupervisor)
    loop_opts = Keyword.drop(opts, [:task_supervisor])

    Task.Supervisor.start_child(
      task_supervisor,
      fn -> process_message(session_id, message, loop_opts) end,
      restart: :temporary
    )
  end

  @doc "Cancel a running session and its registered sub-agents."
  @spec cancel(session_id()) :: :ok | {:error, term()}
  def cancel(session_id), do: Loop.cancel(session_id)

  @doc """
  Queue a mid-turn steer directive for a running session (primitive #32).

  The text is injected into the live ReAct loop at its next step boundary so the
  agent adapts without the turn being cancelled. See `Loop.steer/2`.
  """
  @spec steer(session_id(), String.t()) :: :ok
  def steer(session_id, text), do: Loop.steer(session_id, text)

  @doc "Stop a live loop process and forget runtime tracking."
  @spec stop_session(session_id()) :: :ok | {:error, :not_found} | {:error, term()}
  def stop_session(session_id) do
    # Cascade first: a stopped parent must not strand its fleet delegates as
    # live loops holding full transcripts. Each child's stop recurses here, so a
    # deep tree unwinds level by level. Best-effort — never blocks this stop.
    _ = OptimalSystemAgent.Agent.Fleet.stop_children(session_id)

    case lookup_loop(session_id) do
      {:ok, pid, _owner} ->
        GenServer.stop(pid, :normal)
        untrack_session(session_id)

      :error ->
        {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  @doc "Get the current loop state if the loop is active."
  @spec get_state(session_id()) :: {:ok, map()} | {:error, term()}
  def get_state(session_id), do: Loop.get_state(session_id)

  @doc "Proactively compact a live session's context buffer (summarize older turns)."
  @spec proactive_compact(session_id()) :: {:ok, map()} | {:error, term()}
  def proactive_compact(session_id, instructions \\ nil),
    do: Loop.proactive_compact(session_id, instructions)

  @doc "Look up a live loop process."
  @spec lookup_loop(session_id()) :: {:ok, pid(), term()} | :error
  def lookup_loop(session_id) when is_binary(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, owner}] -> {:ok, pid, owner}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def lookup_loop(_), do: :error

  @doc "Enable proactive mode on a live loop."
  @spec set_proactive(session_id()) :: :ok | {:error, :not_found} | {:error, term()}
  def set_proactive(session_id) do
    case lookup_loop(session_id) do
      {:ok, pid, _owner} ->
        GenServer.call(pid, {:set_proactive, true})
        :ok

      :error ->
        {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  @doc "Hot-swap the provider/model for a live loop."
  @spec swap_provider(session_id(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found} | {:error, term()}
  def swap_provider(session_id, provider, model) do
    # Materialise the Loop if it is not running yet.
    #
    # Session Loops start LAZILY — `Channels.Signal` calls `ensure_loop/3` when the
    # first message arrives. Switching the model, however, is something users do
    # BEFORE sending anything (open OSA, pick a model, then start talking), and this
    # path used `lookup_loop/1`, which only *finds* a Loop and never starts one. So a
    # pre-first-turn switch returned `{:error, :not_found}` → HTTP 404
    # `session_not_found` → a "switch failed" toast in the TUI, every time.
    #
    # Materialising here makes this consistent with every other session-scoped entry
    # point, and means the choice is applied to the Loop the first turn will use.
    _ = ensure_loop(session_id)

    case lookup_loop(session_id) do
      {:ok, pid, _owner} -> GenServer.call(pid, {:swap_provider, provider, model})
      :error -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Forget runtime tracking for a session, and release its per-session state.

  This is OSA's single session-teardown path. Seven per-session cleanup
  functions existed with zero production callers, so every session that ever ran
  left its ETS slice behind for the life of the daemon;
  `Runtime.SessionTeardown.run/1` is what finally calls them. See that module
  for what is released and what is deliberately kept (durable resume artifacts).
  """
  @spec untrack_session(session_id()) :: :ok
  def untrack_session(session_id) do
    ensure_tracked_sessions_table()
    :ets.delete(@tracked_sessions_table, session_id)
    _ = OptimalSystemAgent.Runtime.SessionTeardown.run(session_id)
    :ok
  end

  defp start_loop(session_id, opts) do
    user_id = opts |> Keyword.get(:user_id, "anonymous") |> to_string()
    channel = Keyword.get(opts, :channel, :unknown)

    # Thread working_dir so HTTP/channel sessions persist a real working_dir
    # (enabling directory-scoped resume) instead of the unset app-env nil.
    loop_opts =
      [session_id: session_id, user_id: user_id, channel: channel]
      |> maybe_put_working_dir(Keyword.get(opts, :working_dir))
      |> maybe_put_parent(Keyword.get(opts, :parent_session_id))
      |> put_passthrough_opts(opts)

    case DynamicSupervisor.start_child(
           OptimalSystemAgent.SessionSupervisor,
           {Loop, loop_opts}
         ) do
      {:ok, _pid} ->
        track_session(session_id, %{user_id: user_id, channel: channel})
        Logger.info("[SessionManager] Started Loop for session #{session_id}")
        :ok

      {:error, {:already_started, _pid}} ->
        track_session(session_id, %{user_id: user_id, channel: channel})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_tracked_sessions_table do
    case :ets.whereis(@tracked_sessions_table) do
      :undefined ->
        try do
          :ets.new(@tracked_sessions_table, [:named_table, :set, :public])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # Collision-proof across restarts. System.unique_integer/1 resets to small ints
  # on every BEAM boot, so a fresh session could reuse an id (e.g. "session-1")
  # that already exists in the persistent transcript store and inherit its history.
  #
  # This module got that right first and every other entry point got it wrong, so
  # the reasoning now lives in `Agent.SessionId` and is shared rather than
  # re-derived. Same shape as before, plus a disk check that turns "improbable"
  # into "refused".
  defp default_session_id, do: OptimalSystemAgent.Agent.SessionId.generate("session")
end
