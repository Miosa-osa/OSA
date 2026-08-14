defmodule OptimalSystemAgent.Workspace.Cwd do
  @moduledoc """
  Single source of truth for the agent's working directory.

  Elixir analogue of Claude Code's `src/utils/cwd.ts` (`pwd()`/`getCwd()` +
  `runWithCwdOverride()`). Every consumer that would otherwise call `File.cwd!()`
  — which under `mix osa.serve` resolves to the OSA *source* tree, not the user's
  project — should call `Cwd.get/0` instead.

  Resolution order (highest priority first):

    1. A per-process override in the process dictionary. Set for the duration of
       a turn by the Loop (so tools running in the loop process resolve against
       the session's `working_dir`) and scoped by `with_override/2`.
    2. The declared `working_dir` of the session THIS process is acting for —
       looked up in `:osa_session_workspace` by the `:osa_session_id` the
       process carries. A process dictionary does not cross a spawned Task, so
       (1) alone is only as good as every Task boundary remembering to copy it;
       this is the process-independent record of the same fact and is what makes
       a headless/HTTP-driven session's `working_dir` authoritative rather than
       merely usually-present.
    3. `original_cwd/0` — the user's launch directory, captured once at boot from
       `OSA_ORIGINAL_CWD` (exported by the TUI from its launch dir) or, failing
       that, `File.cwd/0`.

  There is intentionally NO global mutable `Application.put_env(:working_dir)`:
  that made concurrent sessions in different folders clobber each other. The
  live Loop state's `working_dir` participates via mechanism (1) — the Loop
  publishes it into the process dictionary at the start of every turn.
  """

  @process_key :osa_cwd_override
  @original_key {__MODULE__, :original_cwd}
  @session_table :osa_session_workspace

  @doc """
  Capture the process-wide original cwd once, at application boot.

  Prefers an explicit `dir`, then `OSA_ORIGINAL_CWD`, then `File.cwd/0`. The
  TUI sets `OSA_ORIGINAL_CWD` to its launch directory when it spawns the
  backend, so the backend's identity reflects the user's project rather than
  wherever `mix.exs` happens to live.
  """
  @spec set_original_cwd(String.t() | nil) :: String.t()
  def set_original_cwd(dir \\ nil) do
    resolved =
      cond do
        is_binary(dir) and dir != "" -> dir
        (env = System.get_env("OSA_ORIGINAL_CWD")) not in [nil, ""] -> env
        true -> safe_file_cwd()
      end

    expanded = Path.expand(resolved)
    :persistent_term.put(@original_key, expanded)
    expanded
  end

  @doc "The user's launch directory (boot-captured). Falls back to File.cwd/0."
  @spec original_cwd() :: String.t()
  def original_cwd do
    case :persistent_term.get(@original_key, nil) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> safe_file_cwd()
    end
  end

  @doc "Resolved current working directory. Never raw `File.cwd!()`."
  @spec get() :: String.t()
  def get do
    case Process.get(@process_key) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        session_dir(Process.get(:osa_session_id)) || original_cwd()
    end
  end

  # ── Session workspace registry ────────────────────────────────────────
  #
  # `working_dir` is a property of the SESSION, not of whatever process happens
  # to be running a step of it. Recording it here means any process that knows
  # which session it is acting for can resolve the session's workspace without
  # depending on a process-dictionary value having been copied across every
  # Task boundary between the Loop and itself.

  @doc "Record a session's declared working directory. Idempotent, never raises."
  @spec put_session_dir(String.t() | nil, String.t() | nil) :: :ok
  def put_session_dir(session_id, dir)
      when is_binary(session_id) and session_id != "" and is_binary(dir) and dir != "" do
    :ets.insert(@session_table, {session_id, Path.expand(dir)})
    :ok
  rescue
    _ -> :ok
  end

  def put_session_dir(_session_id, _dir), do: :ok

  @doc "The declared working directory of `session_id`, or nil when unknown."
  @spec session_dir(String.t() | nil) :: String.t() | nil
  def session_dir(session_id) when is_binary(session_id) and session_id != "" do
    case :ets.lookup(@session_table, session_id) do
      [{^session_id, dir}] when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def session_dir(_session_id), do: nil

  @doc "Forget a session's workspace record (session end)."
  @spec drop_session_dir(String.t() | nil) :: :ok
  def drop_session_dir(session_id) when is_binary(session_id) and session_id != "" do
    :ets.delete(@session_table, session_id)
    :ok
  rescue
    _ -> :ok
  end

  def drop_session_dir(_session_id), do: :ok

  @doc """
  Create the session-workspace table. Called once from `Application.start/2`;
  safe to call again (a second call is a no-op) so tests that run without the
  full application tree can create it on demand.
  """
  @spec init_session_table() :: :ok
  def init_session_table do
    case :ets.whereis(@session_table) do
      :undefined ->
        :ets.new(@session_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Alias for `get/0` (CC parity naming)."
  @spec pwd() :: String.t()
  def pwd, do: get()

  @doc "Publish a per-process cwd override (no-op for blank values)."
  @spec put_process_override(String.t() | nil) :: :ok
  def put_process_override(dir) when is_binary(dir) and dir != "" do
    Process.put(@process_key, dir)
    :ok
  end

  def put_process_override(_), do: :ok

  @doc "Drop any per-process cwd override for the current process."
  @spec clear_process_override() :: :ok
  def clear_process_override do
    Process.delete(@process_key)
    :ok
  end

  @doc """
  Run `fun` with `dir` as the resolved cwd for the current process, restoring
  the previous override afterward. Elixir analogue of `runWithCwdOverride`.
  """
  @spec with_override(String.t(), (-> result)) :: result when result: var
  def with_override(dir, fun) when is_binary(dir) and dir != "" and is_function(fun, 0) do
    prev = Process.get(@process_key)
    Process.put(@process_key, dir)

    try do
      fun.()
    after
      case prev do
        nil -> Process.delete(@process_key)
        prev -> Process.put(@process_key, prev)
      end
    end
  end

  def with_override(_dir, fun) when is_function(fun, 0), do: fun.()

  @doc """
  Git-root-aware workspace identity for the resolved (or given) directory.

  Mirrors CC's `detectRepository`/`findCanonicalGitRoot`: the project name is the
  basename of the enclosing git root when inside a repo, else the basename of the
  directory — with the home directory rendered as `~` (so a home-dir launch is
  never mislabelled with the username).
  """
  @spec identity(String.t()) :: %{
          cwd: String.t(),
          project_root: String.t(),
          name: String.t(),
          is_git: boolean()
        }
  def identity(dir \\ get()) do
    expanded = Path.expand(dir)
    root = git_root(expanded)
    base = root || expanded

    %{
      cwd: expanded,
      project_root: base,
      name: project_name(base),
      is_git: root != nil
    }
  end

  @doc "Human-friendly name for a directory (repo/dir basename, or `~` for home)."
  @spec project_name(String.t()) :: String.t()
  def project_name(dir) do
    expanded = Path.expand(dir)
    home = user_home()

    cond do
      home != "" and expanded == Path.expand(home) ->
        "~"

      true ->
        case Path.basename(expanded) do
          "" -> "~"
          "/" -> "~"
          name -> name
        end
    end
  end

  @doc "Absolute git top-level for `dir`, or nil when not inside a git repo."
  @spec git_root(String.t()) :: String.t() | nil
  def git_root(dir) do
    case OptimalSystemAgent.Git.cmd(["-C", dir, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          root -> root
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp user_home do
    System.user_home() || System.get_env("HOME") || ""
  end

  defp safe_file_cwd do
    case File.cwd() do
      {:ok, dir} -> dir
      _ -> "."
    end
  end
end
