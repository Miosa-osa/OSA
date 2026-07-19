defmodule OptimalSystemAgent.Workspace.FastWorktree.Metadata do
  @moduledoc """
  Crash-recovery sidecar metadata for fast worktrees.

  Every worktree created by `FastWorktree` writes a small JSON sidecar under
  `<worktrees_dir>/.osa-meta/<safe_id>.json`. The sidecar is the source of truth
  for the crash-recovery sweep: it records enough to locate + deregister an
  orphaned worktree (its path, branch, owning repo) and a **boot token** that
  distinguishes worktrees created by the *current* VM run from leftovers of a
  crashed previous run.

  This mirrors grok fast-worktree's SQLite worktree registry (`db/schema.rs`),
  scaled down to a per-worktree JSON file so there is no schema/migration
  surface and no shared-DB contention between concurrent sessions.

  Fields:

    * `id`          — sanitized worktree id (also the sidecar basename)
    * `path`        — absolute worktree directory
    * `branch`      — git branch created for the worktree
    * `repo_dir`    — the source repository the worktree belongs to
    * `tier`        — which creation tier populated it (:btrfs/:reflink/:copy/:git)
    * `created_at`  — ISO-8601 timestamp
    * `created_unix`— unix seconds (cheap comparisons)
    * `boot_token`  — identifies the VM run that created it
  """

  require Logger

  @meta_subdir ".osa-meta"
  @boot_key {__MODULE__, :boot_token}

  @doc """
  A stable token for the lifetime of this VM. Generated once and cached in
  `:persistent_term`. Sidecars carry the token of the run that created them, so
  a startup sweep can treat any sidecar with a *different* token as a crash
  leftover to reclaim.
  """
  @spec boot_token() :: String.t()
  def boot_token do
    case :persistent_term.get(@boot_key, nil) do
      token when is_binary(token) ->
        token

      _ ->
        token = generate_boot_token()
        # put_new-style: only set if still unset to avoid a race between two
        # concurrent first-callers picking different tokens.
        case :persistent_term.get(@boot_key, nil) do
          existing when is_binary(existing) -> existing
          _ -> :persistent_term.put(@boot_key, token) && token
        end
    end
  end

  defp generate_boot_token do
    # Tie to the OS process so a reused BEAM (unlikely) still rotates on restart.
    os_pid = System.pid()
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{os_pid}-#{rand}"
  end

  @doc "Directory holding sidecar files for a given worktrees root."
  @spec meta_dir(String.t()) :: String.t()
  def meta_dir(worktrees_dir), do: Path.join(worktrees_dir, @meta_subdir)

  @doc "Absolute path of the sidecar file for `id` under `worktrees_dir`."
  @spec sidecar_path(String.t(), String.t()) :: String.t()
  def sidecar_path(worktrees_dir, id) do
    Path.join(meta_dir(worktrees_dir), "#{id}.json")
  end

  @doc """
  Persist a sidecar for a freshly created worktree. Best-effort: a write
  failure is logged but never fails worktree creation (the worktree itself is
  already valid; the sidecar only aids later cleanup).
  """
  @spec write(String.t(), map()) :: :ok
  def write(worktrees_dir, %{id: id} = attrs) do
    record =
      %{
        "id" => id,
        "path" => attrs[:path],
        "branch" => attrs[:branch],
        "repo_dir" => attrs[:repo_dir],
        "tier" => to_string(attrs[:tier] || :unknown),
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "created_unix" => System.os_time(:second),
        "boot_token" => boot_token()
      }

    dir = meta_dir(worktrees_dir)
    File.mkdir_p!(dir)
    path = sidecar_path(worktrees_dir, id)
    File.write!(path, Jason.encode!(record, pretty: true))
    :ok
  rescue
    e ->
      Logger.warning("[fast_worktree] sidecar write failed: #{Exception.message(e)}")
      :ok
  end

  @doc "Remove the sidecar for `id` (best-effort)."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(worktrees_dir, id) do
    _ = File.rm(sidecar_path(worktrees_dir, id))
    :ok
  end

  @doc """
  Remove the sidecar that points at `path`, whatever its id. Used by teardown
  which is keyed on the worktree path rather than the id.
  """
  @spec delete_by_path(String.t(), String.t()) :: :ok
  def delete_by_path(worktrees_dir, path) do
    target = Path.expand(path)

    for record <- list(worktrees_dir), record["path"] && Path.expand(record["path"]) == target do
      delete(worktrees_dir, record["id"])
    end

    :ok
  end

  @doc "Read and decode every sidecar under `worktrees_dir` (skips malformed)."
  @spec list(String.t()) :: [map()]
  def list(worktrees_dir) do
    dir = meta_dir(worktrees_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(fn f ->
          case read_one(Path.join(dir, f)) do
            {:ok, record} -> [record]
            :error -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp read_one(path) do
    with {:ok, body} <- File.read(path),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      _ -> :error
    end
  end
end
