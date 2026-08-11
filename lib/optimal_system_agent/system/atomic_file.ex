defmodule OptimalSystemAgent.System.AtomicFile do
  @moduledoc """
  One crash-safe file replacement, used everywhere instead of hand-rolled
  `write tmp; rename tmp` pairs.

  Every hand-rolled copy in this tree got the ordering right and the rest
  wrong. Three defects were common to all of them:

    * **Symlinks were clobbered.** `rename/2` replaces the *link*, not the
      link's target. A `~/.osa/config.toml` symlinked into a dotfiles repo
      became a regular file on the first write, silently detaching the user
      from their own version control.

    * **Mode was dropped.** The replacement is a brand new inode created under
      the process umask, so a `0600` credentials file came back `0644`.

    * **No fsync.** `rename/2` is atomic with respect to *readers*, but not
      with respect to power loss: the directory entry can reach disk before
      the data blocks do, leaving a correctly-named empty or garbage file.
      `fsync` before the rename is what makes "crash-safe" true rather than
      merely intended.

  The write is still last-writer-wins across processes — this replaces whole
  files and makes no attempt at merge. Callers that need concurrent-writer
  safety need a lock as well, not just this.
  """

  # A symlink chain longer than this is a loop in practice.
  @max_link_hops 32

  @type option :: {:mode, non_neg_integer()} | {:default_mode, non_neg_integer()}

  @doc """
  Atomically replace `path` with `contents`.

  Resolves symlinks, preserves the existing file's mode, fsyncs the data, then
  renames into place. Creates the parent directory if it is missing.

  Options:

    * `:mode` — force this mode instead of inheriting the existing file's.
    * `:default_mode` — mode to use when `path` does not exist yet. Defaults to
      leaving the umask to decide.
  """
  @spec write(Path.t(), iodata(), [option()]) :: :ok | {:error, term()}
  def write(path, contents, opts \\ []) when is_binary(path) do
    target = resolve_symlink(path)
    dir = Path.dirname(target)

    with :ok <- ensure_dir(dir),
         {:ok, tmp} <- write_tmp(dir, contents),
         :ok <- apply_mode(tmp, target, opts),
         :ok <- rename(tmp, target) do
      _ = sync_dir(dir)
      :ok
    end
  end

  @doc "Bang variant of `write/3`. Raises `File.Error` on failure."
  @spec write!(Path.t(), iodata(), [option()]) :: :ok
  def write!(path, contents, opts \\ []) when is_binary(path) do
    case write(path, contents, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "write to file",
          path: IO.chardata_to_string(path)
    end
  end

  @doc """
  Resolve `path` through any chain of symlinks, returning the real path that a
  write should land on.

  Unresolvable, dangling, and looping links all fall back to the path as given
  — the caller's write then creates a regular file there, which is what the
  hand-rolled code always did. Relative link targets resolve against the
  directory holding the link, per POSIX.
  """
  @spec resolve_symlink(Path.t()) :: Path.t()
  def resolve_symlink(path), do: resolve_symlink(path, @max_link_hops)

  defp resolve_symlink(path, 0), do: path

  defp resolve_symlink(path, hops) do
    case :file.read_link(path) do
      {:ok, link} ->
        link
        |> to_string()
        |> then(fn l ->
          if Path.type(l) == :absolute, do: l, else: Path.expand(l, Path.dirname(path))
        end)
        |> resolve_symlink(hops - 1)

      # Not a link, does not exist, or not readable — write where we were told.
      {:error, _} ->
        path
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The temp file is created in the *target's* directory so the rename is a
  # same-filesystem metadata operation. A temp under /tmp would make it a
  # copy, which is not atomic.
  defp write_tmp(dir, contents) do
    tmp = Path.join(dir, ".osa-atomic-#{System.unique_integer([:positive])}.tmp")

    case File.open(tmp, [:write, :binary, :raw]) do
      {:ok, fd} ->
        result =
          with :ok <- :file.write(fd, contents) do
            # The whole point: get the bytes onto the platter before the
            # directory entry that names them.
            :file.sync(fd)
          end

        _ = :file.close(fd)

        case result do
          :ok ->
            {:ok, tmp}

          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_mode(tmp, target, opts) do
    mode =
      case Keyword.fetch(opts, :mode) do
        {:ok, m} -> m
        :error -> existing_mode(target, opts)
      end

    case mode do
      nil ->
        :ok

      m ->
        # A failure here is not worth losing the write over — a correct file
        # with the wrong bits beats no file at all.
        _ = File.chmod(tmp, Bitwise.band(m, 0o7777))
        :ok
    end
  end

  defp existing_mode(target, opts) do
    case File.stat(target) do
      {:ok, %File.Stat{mode: mode}} -> mode
      {:error, _} -> Keyword.get(opts, :default_mode)
    end
  end

  defp rename(tmp, target) do
    case File.rename(tmp, target) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  # Renames are only durable once the *directory* is synced too. Erlang has no
  # portable directory fd, so this is best-effort and its failure is not the
  # caller's problem.
  defp sync_dir(dir) do
    case :file.open(dir, [:read, :raw]) do
      {:ok, fd} ->
        _ = :file.sync(fd)
        :file.close(fd)

      {:error, _} ->
        :ok
    end
  end
end
