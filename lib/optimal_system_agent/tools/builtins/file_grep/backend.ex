defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Backend do
  @moduledoc """
  Which engine answered a `file_grep`, and whether the caller was told.

  ## The defect this exists to close

  `file_grep` has two engines: ripgrep, and a pure-Elixir walk used when
  ripgrep cannot be run. The fallback was reached through a bare `rescue` around
  `System.cmd("rg", …)`, which raises `:enoent` whenever the binary is not on
  the BEAM's PATH. That rescue could not distinguish "ripgrep ran and failed"
  from "ripgrep does not exist here", and it said nothing either way.

  Measured on a 118-session corpus: **all 862 `file_grep` calls were served by
  the fallback.** Not most — all of them. The ripgrep path never executed once,
  in any session, and no log line, no doctor row and no tool result mentioned
  it. Corroborating signal from the same corpus: of the 50 calls that passed
  `context_lines` and got matches back, ZERO results contain a context line,
  because the fallback ignored the parameter.

  The fallback's own bugs (500-file cap, non-recursive glob, dropped
  `context_lines`) are fixed. This module fixes the remaining half: the
  substitution is no longer silent.

  ## What "observable" means here

  A tool cannot put ripgrep on the PATH. It can refuse to degrade quietly, on
  three surfaces, each aimed at a different reader:

    * **`Logger.warning`, once per session** (`warn_missing_once/1`) — for the
      operator reading daemon logs. Once per session, not once per call: 862
      identical lines is not a signal, it is noise that trains people to filter
      the channel.
    * **`osa doctor`** (`status/0`) — for the user who suspects something is
      wrong and goes looking. This is the only surface a user consults
      deliberately, so it carries the install instruction.
    * **The tool result itself** (`empty_result_note/1`) — for the model, which
      reads nothing else. Attached only when the answer is "nothing found",
      because that is the answer a degraded backend gets wrong, and it is the
      one place a second opinion is worth its tokens.

  ## Why the missing/failed distinction is load-bearing

  `:missing` means the fallback was used because there was no choice — a
  degradation the operator can fix by installing a package. `:failed` means
  ripgrep exists and exited badly — a different problem with a different fix
  (a malformed pattern, a permissions error, a broken install). Collapsing them,
  as the old `{:fallback, :rg_not_found}` did for both, is what made the
  environment problem invisible for 862 calls.

  Deliberately NOT cached: `System.find_executable/1` is a PATH scan of a few
  directories, once per search, against a walk that reads thousands of files. A
  cache would mean a user who installs ripgrep mid-session keeps being told it
  is missing, and `osa doctor` would report a stale answer from whenever the
  node happened to boot. The *warning* is deduplicated; the *detection* is not.
  """

  require Logger

  alias OptimalSystemAgent.Tools.UseContext

  @binary "rg"
  @warn_once_table :osa_file_grep_backend_warned

  @install_hint "Install ripgrep to restore it: `apt install ripgrep` / `brew install ripgrep` / " <>
                  "`cargo install ripgrep`. If it IS installed, it is not on the PATH the OSA " <>
                  "daemon inherited — daemons started from a desktop launcher or a service " <>
                  "manager do not read your shell profile. Restart the daemon from a shell " <>
                  "where `command -v rg` succeeds (`osa stop`, then `osa`)."

  @typedoc """
  Which engine served a search, and — for the fallback — why it was reached.
  """
  @type t :: :ripgrep | {:fallback, :missing} | {:fallback, :failed}

  @doc """
  Absolute path to the ripgrep binary, or `nil` when it is not on the PATH.

  Uses `System.find_executable/1` rather than attempting the spawn and rescuing,
  so "not installed" is established BEFORE a failure has to be interpreted. The
  rescue in the caller stays as a backstop for the races this cannot see (the
  binary deleted between the lookup and the spawn, an exec permission error),
  but it is no longer how the common case is detected.
  """
  @spec executable() :: String.t() | nil
  def executable, do: System.find_executable(@binary)

  @doc """
  `true` when ripgrep can be executed from this node.
  """
  @spec available?() :: boolean()
  def available?, do: executable() != nil

  @doc """
  `true` when `path` is itself a symlink, tested with `File.lstat/1`, which does
  NOT resolve the link, unlike `File.stat/1` and `File.dir?/1`.

  The pure-Elixir `file_grep` fallback (reached only when ripgrep is absent)
  descends the tree with `File.ls/1` and classifies entries with `File.dir?/1`,
  which FOLLOWS symlinks. A self-referential directory symlink (an Elixir
  `_build` is full of symlinked dep dirs, and any `a -> ..` loops onto itself)
  then walks unboundedly. ripgrep skips symlink loops by default; this predicate
  restores the same guard for the fallback, in one place both engines' policy can
  point at.

  NOTE(v1056): the fallback walk lives in `FileGrep.Handler.walk/2`, which is
  outside this workstream's edit set, so this guard is not yet wired in. That
  `walk/2` must drop any directory entry for which this returns `true` before
  adding it to the descent frontier (e.g. `Enum.reject(dirs, &Backend.symlink?/1)`
  alongside the existing `@pruned_dirs` prune), so `.git`/`_build`/`deps`/
  `node_modules` continue to be pruned DURING descent and symlinked dirs are
  never followed.
  """
  @spec symlink?(String.t()) :: boolean()
  def symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  @doc """
  Structured availability for `osa doctor` and the `/doctor` HTTP report.

  Returns `{:pass, detail}` when ripgrep is on the PATH, `{:optional, detail}`
  when it is not.

  `:optional` and not `:fail` on purpose. The fallback is now correct — it walks
  up to `max_fallback_files/0` files with directory-level pruning, honours
  recursive globs and `context_lines`, and reports its own coverage limit when
  it truncates. A node without ripgrep is slower and search results are a lower
  bound, but it is not broken, and marking the whole install NOT READY over a
  missing optional accelerator would train users to ignore the readiness line.
  The row still names the degradation and the fix.
  """
  @spec status() :: {:pass | :optional, String.t()}
  def status do
    case executable() do
      nil ->
        {:optional,
         "ripgrep (rg) NOT on the daemon's PATH — file_grep is served by the slower " <>
           "pure-Elixir fallback, and its results are a lower bound rather than proof of " <>
           "absence. " <> @install_hint}

      path ->
        {:pass, "ripgrep available at #{path} — file_grep uses it"}
    end
  end

  @doc """
  Log, at most once per session, that a search fell back because ripgrep is
  absent.

  Keyed on `session_id` so a long-running daemon warns again for each new
  session rather than once per node — a user who starts a session an hour later
  and reads the log for it deserves to see the notice in that session's window,
  not to have to scroll back to whenever the node last restarted.

  Only ever called for `{:fallback, :missing}`. A deliberate fallback (ripgrep
  present but exiting non-zero) is a different event and is not routed here.
  """
  @spec warn_missing_once(UseContext.t() | map() | nil) :: :ok
  def warn_missing_once(ctx) do
    key = session_key(ctx)
    ensure_table()

    if :ets.insert_new(@warn_once_table, {key, true}) do
      Logger.warning(
        "[file_grep] ripgrep (#{@binary}) is not on this node's PATH — every search this " <>
          "session is served by the pure-Elixir fallback. Results are a LOWER BOUND, not " <>
          "proof of absence, and are slower. " <> @install_hint
      )
    end

    :ok
  rescue
    # Observability must never be the thing that fails a search.
    _ -> :ok
  end

  @doc """
  Sentence appended to an empty (`no matches`) result naming the engine that
  answered.

  Attached to empty results only. A search that FOUND something has demonstrated
  it can see the tree, so the backend is not in question and the tokens are not
  worth spending. A search that found NOTHING is exactly the claim a degraded
  backend gets wrong, and the model has no other way to learn that the answer
  came from a walk that may have stopped short.

  Returns `""` for the ripgrep backend — the good path stays silent.
  """
  @spec empty_result_note(t()) :: String.t()
  def empty_result_note(:ripgrep), do: ""

  def empty_result_note({:fallback, :missing}) do
    "\n\n(Backend: the pure-Elixir fallback, because ripgrep (rg) is not on this machine's " <>
      "PATH. This answer did NOT come from ripgrep. The fallback prunes dependency and build " <>
      "directories and stops at a file budget; if it reported a coverage limit above, treat " <>
      "this as 'not found in what was searched', not 'absent'.)"
  end

  def empty_result_note({:fallback, :failed}) do
    "\n\n(Backend: the pure-Elixir fallback. ripgrep IS installed here but exited with an " <>
      "error for this search, so the fallback answered instead. If the pattern uses unusual " <>
      "regex syntax, that is the likely cause.)"
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp session_key(%UseContext{session_id: id}), do: id || "_no_session_"
  defp session_key(%{session_id: id}) when is_binary(id), do: id
  defp session_key(_), do: "_no_session_"

  defp ensure_table do
    case :ets.whereis(@warn_once_table) do
      :undefined ->
        try do
          :ets.new(@warn_once_table, [:named_table, :public, :set, write_concurrency: true])
        rescue
          # Lost the race to another process creating it. Fine — it exists now.
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc false
  # Test seam: forget which sessions have been warned, so a test can assert the
  # warning fires and then assert it does NOT fire again.
  @spec reset_warnings() :: :ok
  def reset_warnings do
    ensure_table()
    :ets.delete_all_objects(@warn_once_table)
    :ok
  rescue
    _ -> :ok
  end
end
