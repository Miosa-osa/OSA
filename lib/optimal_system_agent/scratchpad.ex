defmodule OptimalSystemAgent.Scratchpad do
  @moduledoc """
  File-based shared scratchpad — a real, persistent, inspectable coordination
  surface for a coordinator and the workers it spawns.

  This is OSA's answer to Claude Code's `scratchpadDir`: a real directory that
  is injected into every spawned worker so a coordinator and its teammates
  coordinate through actual files (notes, plans, partial results) instead of
  only in-memory state.

  ## Relationship to the ETS `Team` scratchpad

  `OptimalSystemAgent.Team` keeps a fast, ephemeral, per-agent scratchpad in
  ETS. This module COMPLEMENTS it — it does not replace it:

    * `Team` (ETS)   — transient, lock-free, lost on restart. Best for hot
      inter-agent coordination during a single live run.
    * `Scratchpad`   — durable (survives restart), inspectable (the operator
      can `ls`/`cat` the directory), and shared across agent generations.

  ## Layout (resolved at RUNTIME — never frozen at compile time)

      <ConfigFile.config_dir()>/scratchpad/<scratchpad_id>/
      ├── <entry>.md          # arbitrary worker-created files
      ├── plan.md
      └── ...

  `config_dir/0` respects the `:config_dir` / `:bootstrap_dir` app-env seam, so
  a test can point the whole tree at a tmp dir without touching the real
  `~/.osa`.

  ## Coordination id (how a worker sees the SAME directory as its parent)

  The `scratchpad_id` is the shared coordination key. A top-level session uses
  its own `session_id`. A spawned worker's `session_id` is different
  (`agent:<parent>:N`), so a naive per-session key would ISOLATE it. To keep
  the directory SHARED, `session_root/1` walks `RunStore`'s
  `parent_session_id` chain up to the root session — both the parent and all of
  its (transitive) workers resolve to the SAME root, hence the same directory.

  ## Path safety

  Every entry name is scoped strictly INSIDE the scratchpad directory. Names
  containing `..` segments, absolute paths, or `~` are rejected; the resolved
  absolute path is re-checked against the scratchpad dir prefix so nothing can
  escape via symlink-free traversal.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile

  @index_file "INDEX.log"

  @type scratchpad_id :: String.t()
  @type entry :: String.t()

  # ── Directory resolution (runtime) ────────────────────────────────────

  @doc "Root directory holding every session/team scratchpad. Runtime-resolved."
  @spec root_dir() :: String.t()
  def root_dir, do: Path.join(ConfigFile.config_dir(), "scratchpad")

  @doc """
  Absolute directory for one `scratchpad_id`. The id is sanitized (only word
  chars, dot, and dash survive; path separators and `..` collapse to `_`) so a
  crafted id cannot select a sibling directory.
  """
  @spec dir_for(scratchpad_id()) :: String.t()
  def dir_for(scratchpad_id) do
    Path.join(root_dir(), sanitize_id(scratchpad_id))
  end

  @doc "Create the scratchpad directory for `scratchpad_id` if absent. Returns the dir."
  @spec ensure_dir(scratchpad_id()) :: String.t()
  def ensure_dir(scratchpad_id) do
    dir = dir_for(scratchpad_id)
    File.mkdir_p(dir)
    dir
  end

  @doc """
  Resolve the SHARED coordination id for a session by walking `RunStore`'s
  parent chain up to the root. A top-level session (no `RunStore` parent)
  resolves to itself; a spawned worker resolves to its root ancestor, so it
  shares the parent's directory. A `seen` set guards a malformed/cyclic chain.
  """
  @spec session_root(scratchpad_id()) :: scratchpad_id()
  def session_root(session_id) when is_binary(session_id) do
    walk_root(session_id, MapSet.new())
  end

  def session_root(other), do: other

  defp walk_root(id, seen) do
    if MapSet.member?(seen, id) do
      id
    else
      case safe_run_parent(id) do
        parent when is_binary(parent) and parent != "" -> walk_root(parent, MapSet.put(seen, id))
        _ -> id
      end
    end
  end

  defp safe_run_parent(id) do
    case OptimalSystemAgent.Agent.RunStore.get(id) do
      %{parent_session_id: parent} -> parent
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ── Entry operations ──────────────────────────────────────────────────

  @doc """
  Write (overwrite) an entry. Returns `{:ok, abs_path}` or `{:error, reason}`
  when the name escapes the scratchpad directory.
  """
  @spec write(scratchpad_id(), entry(), iodata()) :: {:ok, String.t()} | {:error, String.t()}
  def write(scratchpad_id, name, content) do
    with {:ok, path} <- resolve(scratchpad_id, name),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      log_index(scratchpad_id, "write", name)
      {:ok, path}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, posix} -> {:error, "write failed: #{inspect(posix)}"}
    end
  end

  @doc "Append to an entry (creating it if absent). Returns `{:ok, abs_path}`."
  @spec append(scratchpad_id(), entry(), iodata()) :: {:ok, String.t()} | {:error, String.t()}
  def append(scratchpad_id, name, content) do
    with {:ok, path} <- resolve(scratchpad_id, name),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content, [:append]) do
      log_index(scratchpad_id, "append", name)
      {:ok, path}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, posix} -> {:error, "append failed: #{inspect(posix)}"}
    end
  end

  @doc "Read an entry. Returns `{:ok, content}`, `{:error, :not_found}`, or a path error."
  @spec read(scratchpad_id(), entry()) :: {:ok, String.t()} | {:error, term()}
  def read(scratchpad_id, name) do
    with {:ok, path} <- resolve(scratchpad_id, name) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, :not_found}
        {:error, posix} -> {:error, posix}
      end
    end
  end

  @doc """
  List all entries with size and mtime, newest first. Excludes the internal
  index log. Returns `[%{name, size, mtime}]`.
  """
  @spec list(scratchpad_id()) :: [%{name: String.t(), size: non_neg_integer(), mtime: term()}]
  def list(scratchpad_id) do
    dir = dir_for(scratchpad_id)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 == @index_file))
        |> Enum.map(fn name ->
          path = Path.join(dir, name)

          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{size: size, mtime: mtime, type: :regular}} ->
              %{name: name, size: size, mtime: mtime}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.mtime, :desc)

      _ ->
        []
    end
  end

  @doc "Delete an entry. Returns `:ok` even when the entry was already absent."
  @spec delete(scratchpad_id(), entry()) :: :ok | {:error, String.t()}
  def delete(scratchpad_id, name) do
    with {:ok, path} <- resolve(scratchpad_id, name) do
      File.rm(path)
      log_index(scratchpad_id, "delete", name)
      :ok
    end
  end

  # ── Path safety ───────────────────────────────────────────────────────

  @doc """
  Resolve `name` to an absolute path INSIDE the scratchpad directory, or
  `{:error, reason}` when it would escape.

  Rejects absolute paths, `~`-expansion, and any `..` segment, then re-checks
  the fully-expanded path against the scratchpad-dir prefix as defense in depth.
  """
  @spec resolve(scratchpad_id(), entry()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(scratchpad_id, name) when is_binary(name) do
    dir = dir_for(scratchpad_id)
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "entry name must not be blank"}

      String.starts_with?(trimmed, "/") or String.starts_with?(trimmed, "~") ->
        {:error, "entry name must be relative to the scratchpad dir (no absolute or ~ paths)"}

      ".." in Path.split(trimmed) ->
        {:error, "entry name must not contain '..' path segments"}

      true ->
        candidate = Path.expand(Path.join(dir, trimmed))
        # Final containment check — the expanded path must stay under `dir`.
        if candidate == dir or String.starts_with?(candidate, dir <> "/") do
          {:ok, candidate}
        else
          {:error, "entry name escapes the scratchpad directory"}
        end
    end
  end

  def resolve(_scratchpad_id, _name), do: {:error, "entry name must be a string"}

  # ── Private ───────────────────────────────────────────────────────────

  # Keep only safe id characters; collapse everything else (including `/` and
  # `.`-runs that could form `..`) to `_` so a crafted id can't select a
  # sibling directory or traverse upward.
  defp sanitize_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> case do
      "" -> "default"
      s -> s
    end
  end

  # Append-only human-readable index/log of coordination activity. Best-effort:
  # a failed index write never fails the underlying entry operation.
  defp log_index(scratchpad_id, op, name) do
    line = "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{op} #{name}\n"
    File.write(Path.join(dir_for(scratchpad_id), @index_file), line, [:append])
    :ok
  rescue
    _ -> :ok
  end
end
