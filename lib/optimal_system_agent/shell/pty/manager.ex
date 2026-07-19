defmodule OptimalSystemAgent.Shell.Pty.Manager do
  @moduledoc """
  Facade over the interactive-PTY mechanism — the interactive complement to
  `Shell.BackgroundManager`.

  Owns the lifecycle plumbing (a `DynamicSupervisor` +
  `Registry`) and hands out opaque, named session ids. The builtin `pty_*`
  tools (and tests) call into this module; they never touch `Session` directly.

    * `start/2`             — spawn a supervised PTY session, returns `{:ok, id}`
    * `send_keys/2`         — send vim-notation keys to a session
    * `screen/1`            — current screen text
    * `cursor/1`            — 1-based cursor position
    * `scrollback/2`        — scrollback history
    * `wait/3`              — event-driven wait on a screen/lifecycle condition
    * `resize/3`            — reshape the emulator grid
    * `status/1` / `list/0` — liveness + metadata (process-alive + shape-check)
    * `stop/1`              — kill the child and stop the session

  Sessions are addressed by their generated id OR by a caller-supplied `:name`.
  The supervising `DynamicSupervisor`
  (`OptimalSystemAgent.Shell.Pty.Supervisor`) and lookup `Registry`
  (`OptimalSystemAgent.Shell.Pty.Registry`) are started in
  `OptimalSystemAgent.Supervisors.Infrastructure`.
  """

  alias OptimalSystemAgent.Shell.Pty.Session

  @registry OptimalSystemAgent.Shell.Pty.Registry
  @supervisor OptimalSystemAgent.Shell.Pty.Supervisor

  @doc """
  Spawn `command` under a pseudo-terminal.

  Options:
    * `:name`       — human-friendly session name (also usable for lookup)
    * `:cols`       — initial columns (default 80)
    * `:rows`       — initial rows (default 24)
    * `:cwd`        — working directory (defaults to the session cwd)
    * `:env`        — `[{key, val}]` extra environment
    * `:session_id` — owning OSA session (for future orphan reaping)

  Returns `{:ok, id}` or `{:error, reason}`. Fails fast with a clear error when
  no pty allocator is available on the host.
  """
  @spec start(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def start(command, opts \\ []) when is_binary(command) do
    case Session.allocator() do
      {:error, :no_pty_allocator} ->
        {:error,
         "no PTY allocator available on this host (need util-linux `script`); " <>
           "cannot run interactive programs — use shell_execute for non-interactive commands"}

      {:ok, _exe, _wrap} ->
        do_start(command, opts)
    end
  end

  defp do_start(command, opts) do
    id = generate_id()
    name = opts[:name]

    child_opts =
      [id: id, command: command, via: via(id)] ++
        Keyword.take(opts, [:name, :cols, :rows, :cwd, :env, :session_id])

    spec = %{
      id: id,
      start: {Session, :start_link, [child_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} ->
        {:ok, id}

      {:error, {:spawn_failed, reason}} ->
        {:error, "failed to spawn PTY: #{reason}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
    |> tap(fn
      {:ok, _} when is_binary(name) -> :ok
      _ -> :ok
    end)
  end

  @doc "Send vim-notation keys to a session (`\"<C-c>\"`, `\"hello<CR>\"`)."
  @spec send_keys(String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys(id_or_name, keys), do: with_session(id_or_name, &Session.send_keys(&1, keys))

  @doc "Send raw bytes to a session's pty."
  @spec send_bytes(String.t(), binary()) :: :ok | {:error, term()}
  def send_bytes(id_or_name, bytes), do: with_session(id_or_name, &Session.send_bytes(&1, bytes))

  @doc "Current screen text."
  @spec screen(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def screen(id_or_name), do: wrap(with_session(id_or_name, &Session.screen/1))

  @doc "1-based cursor position."
  @spec cursor(String.t()) :: {:ok, map()} | {:error, :not_found}
  def cursor(id_or_name), do: wrap(with_session(id_or_name, &Session.cursor/1))

  @doc "Scrollback history (oldest first)."
  @spec scrollback(String.t(), non_neg_integer() | :all) ::
          {:ok, [String.t()]} | {:error, :not_found}
  def scrollback(id_or_name, count \\ :all),
    do: wrap(with_session(id_or_name, &Session.scrollback(&1, count)))

  @doc "Wait on a condition (see `Session.wait/3`)."
  @spec wait(String.t(), tuple() | :gone, non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def wait(id_or_name, condition, timeout_ms) do
    case with_session(id_or_name, &Session.wait(&1, condition, timeout_ms)) do
      {:error, reason} -> {:error, reason}
      outcome when is_map(outcome) -> {:ok, outcome}
    end
  end

  @doc "Reshape the emulator grid (see `Session` resize caveat)."
  @spec resize(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, :not_found}
  def resize(id_or_name, cols, rows),
    do: with_session(id_or_name, &Session.resize(&1, cols, rows))

  @doc "Status snapshot for a session."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(id_or_name), do: wrap(with_session(id_or_name, &Session.status/1))

  @doc "Kill the child and stop the session."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(id_or_name), do: with_session(id_or_name, &Session.stop/1)

  @doc "Snapshots of all live sessions (process-alive + status shape-check)."
  @spec list() :: [map()]
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      # Only the primary id-keyed registrations (skip {:name, _} aliases).
      {key, pid} when is_binary(key) ->
        if Process.alive?(pid) do
          try do
            [Session.status(pid)]
          catch
            _, _ -> []
          end
        else
          []
        end

      _ ->
        []
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp with_session(id_or_name, fun) do
    case resolve(id_or_name) do
      {:ok, pid} -> fun.(pid)
      :error -> {:error, :not_found}
    end
  end

  # Resolve an id (primary key) or a name (secondary {:name, _} key) to a pid.
  defp resolve(id_or_name) do
    case Registry.lookup(@registry, id_or_name) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Registry.lookup(@registry, {:name, id_or_name}) do
          [{pid, _id}] -> {:ok, pid}
          [] -> :error
        end
    end
  end

  defp wrap({:error, :not_found} = err), do: err
  defp wrap(value), do: {:ok, value}

  defp via(id), do: {:via, Registry, {@registry, id}}

  defp generate_id do
    "pty_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end
end
