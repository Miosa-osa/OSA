defmodule OptimalSystemAgent.Workspace.FastWorktree.Capabilities do
  @moduledoc """
  Runtime filesystem capability detection for fast worktree creation.

  Mirrors grok fast-worktree's `discovery.rs` / `mount_info.rs` / `*/detect.rs`:
  before choosing a creation strategy we probe the *actual* filesystem backing
  the repository, because the fastest tiers (reflink, btrfs snapshot, overlayfs)
  only work on specific filesystems and none can be assumed.

  Probes (all defensive — a failure means "unsupported", never a crash):

    * **reflink** — write a tiny temp file on the repo's fs and attempt
      `cp --reflink=always`. `always` (not `auto`) is essential: `auto`
      silently falls back to a full copy and would report a false positive.
      This is the userland stand-in for the `FICLONE` ioctl grok issues.
    * **btrfs** — `stat -f -c %T` reports the fs type; btrfs also requires the
      `btrfs` CLI to actually take a subvolume snapshot.
    * **overlayfs** — rootless overlay needs the `fuse-overlayfs` binary and an
      `overlay` entry in `/proc/filesystems`. Plain `mount -t overlay` needs
      CAP_SYS_ADMIN we don't assume we have.

  Results are cached in `:persistent_term`, keyed by the filesystem's device id
  so two repos on different mounts get independently-correct answers. Pass
  `refresh: true` to re-probe.
  """

  require Logger

  @cache_prefix {__MODULE__, :caps}

  @type t :: %{
          fs_type: String.t(),
          device: integer() | nil,
          reflink: boolean(),
          btrfs: boolean(),
          overlayfs: boolean(),
          probed_at: integer()
        }

  @doc """
  Detect capabilities for the filesystem backing `dir`. Cached per device.
  """
  @spec detect(String.t(), keyword()) :: t()
  def detect(dir, opts \\ []) do
    dir = Path.expand(dir)
    device = device_id(dir)
    key = {@cache_prefix, device}

    if Keyword.get(opts, :refresh, false) do
      :persistent_term.erase(key)
    end

    case :persistent_term.get(key, nil) do
      %{} = cached ->
        cached

      _ ->
        caps = probe(dir, device)
        :persistent_term.put(key, caps)

        Logger.debug(
          "[fast_worktree] fs caps for #{dir}: fs=#{caps.fs_type} " <>
            "reflink=#{caps.reflink} btrfs=#{caps.btrfs} overlayfs=#{caps.overlayfs}"
        )

        caps
    end
  end

  @doc "Clear all cached capability probes (mainly for tests)."
  @spec clear_cache() :: :ok
  def clear_cache do
    for {{@cache_prefix, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  rescue
    _ -> :ok
  end

  # ── Probes ─────────────────────────────────────────────────────────────

  defp probe(dir, device) do
    fs_type = fs_type(dir)

    %{
      fs_type: fs_type,
      device: device,
      reflink: probe_reflink(dir),
      btrfs: fs_type == "btrfs" and has_cmd?("btrfs"),
      overlayfs: probe_overlayfs(),
      probed_at: System.os_time(:second)
    }
  end

  defp device_id(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{major_device: maj, minor_device: min}} -> maj * 1_000 + (min || 0)
      _ -> nil
    end
  end

  defp fs_type(dir) do
    case System.cmd("stat", ["-f", "-c", "%T", dir], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  # Attempt a real reflink clone in a temp file on the target fs. `always`
  # forces a genuine CoW clone or a hard error — the only reliable probe.
  defp probe_reflink(dir) do
    unless has_cmd?("cp"), do: throw(:no_cp)

    src = Path.join(dir, ".osa_reflink_probe_#{unique()}")
    dst = src <> ".clone"

    try do
      File.write!(src, "osa-reflink-probe")

      case System.cmd("cp", ["--reflink=always", src, dst], stderr_to_stdout: true) do
        {_out, 0} -> true
        _ -> false
      end
    rescue
      _ -> false
    after
      _ = File.rm(src)
      _ = File.rm(dst)
    end
  catch
    :no_cp -> false
  end

  defp probe_overlayfs do
    has_cmd?("fuse-overlayfs") and overlay_in_proc?()
  end

  defp overlay_in_proc? do
    case File.read("/proc/filesystems") do
      {:ok, body} -> String.contains?(body, "overlay")
      _ -> false
    end
  end

  defp has_cmd?(cmd), do: System.find_executable(cmd) != nil

  defp unique, do: System.unique_integer([:positive])
end
