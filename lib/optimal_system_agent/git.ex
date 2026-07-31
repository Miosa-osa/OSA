defmodule OptimalSystemAgent.Git do
  @moduledoc """
  Hardened `git` invocation — the single place OSA shells out to git.

  ## Why this exists

  Git reads configuration from the *repository it is pointed at*
  (`.git/config`, and `.gitattributes` for filter selection). Several of those
  config keys name a **program git will execute**. That means running an
  innocuous, read-only-looking command such as `git status` or `git diff`
  inside a repository somebody else authored is enough to execute arbitrary
  code on the operator's machine:

    * `core.hooksPath` + a hook script → runs on commit/merge/checkout/status-ish
      porcelain,
    * `core.fsmonitor` → an arbitrary command git spawns to enumerate changes
      (fires on `status`, `diff`, `add`, …),
    * `filter.<driver>.clean` / `.smudge` / `.process` → run whenever a path
      with that `filter` attribute is diffed, staged, or checked out,
    * `diff.external` and `diff.<driver>.textconv` / `.command` → run while
      producing a diff.

  OSA clones/inspects repositories it did not author (worktrees, fleet nodes,
  context discovery, project instructions), so every such invocation is
  attacker-reachable. This module neutralizes those keys via `git -c key=value`
  overrides, which take precedence over the repository's own config.

  This mirrors the hardening Codex applies around `get_git_diff`.

  ## Usage

      OptimalSystemAgent.Git.cmd(["status", "--porcelain"], cd: path, stderr_to_stdout: true)

  Argument order, exit codes, and captured output are byte-identical to the
  `System.cmd("git", args, opts)` call it replaces — only inert `-c` overrides
  are prepended ahead of the subcommand, so output parsing is unaffected.

  ### Options

  Everything is forwarded to `System.cmd/3` except:

    * `:hooks` — `:disabled` (default) or `:enabled`. Use `:enabled` only for
      operator/model-initiated *write* commands where skipping the repo's own
      hooks would itself be surprising (e.g. the user-facing `git` tool, which
      deliberately blocks `commit --no-verify`).
    * `:filters` — `:disabled` (default) or `:enabled`. When disabled, OSA
      probes the repo for configured executable clean/smudge/process/textconv
      drivers and blanks them for the duration of the call.
  """

  require Logger

  @null_device if match?({:win32, _}, :os.type()), do: "NUL", else: "/dev/null"

  # POSIX ERE, as understood by `git config --get-regexp`. Matches every config
  # key whose *value* git would treat as a command line to execute while
  # reading/writing worktree content.
  @executable_driver_pattern "^filter\\..*\\.(clean|smudge|process)$"

  @cache_table :osa_git_driver_overrides
  @cache_ttl_ms 60_000

  @typedoc "Same shape as `System.cmd/3` returns."
  @type result :: {Collectable.t(), exit_status :: non_neg_integer()}

  @doc """
  Run `git` with the repository-controlled code-execution vectors disabled.

  Drop-in replacement for `System.cmd("git", args, opts)`.
  """
  @spec cmd([binary()], keyword()) :: result()
  def cmd(args, opts \\ []) when is_list(args) do
    {hardening, sys_opts} = Keyword.split(opts, [:hooks, :filters])
    argv = hardening_args(args, sys_opts, hardening) ++ harden_diff_args(args, hardening)
    System.cmd("git", argv, sys_opts)
  end

  # Subcommands that accept `--no-ext-diff` / `--no-textconv` (verified against
  # git 2.4x). `diff.external` and `diff.<driver>.textconv` are the two
  # remaining execute-a-program config keys, and unlike the filter drivers they
  # CANNOT be neutralized with `-c key=` (git treats the empty value as "run the
  # empty command" and dies), so we use the per-subcommand flags instead.
  @diff_family ~w(diff log show whatchanged diff-tree diff-index diff-files range-diff)

  @doc """
  Inserts `--no-ext-diff --no-textconv` after the subcommand for diff-family
  commands. Returns `args` unchanged for everything else.
  """
  @spec harden_diff_args([binary()], keyword()) :: [binary()]
  def harden_diff_args(args, hardening \\ []) do
    if Keyword.get(hardening, :filters, :disabled) == :enabled do
      args
    else
      case subcommand_index(args, 0) do
        {idx, sub} when sub in @diff_family ->
          {head, tail} = Enum.split(args, idx + 1)

          missing =
            Enum.reject(["--no-ext-diff", "--no-textconv"], &(&1 in args))

          head ++ missing ++ tail

        _ ->
          args
      end
    end
  end

  # Walk past git's global options to find the subcommand token.
  defp subcommand_index([], _idx), do: nil

  defp subcommand_index([opt, _val | rest], idx) when opt in ["-C", "-c"],
    do: subcommand_index(rest, idx + 2)

  defp subcommand_index(["--" <> _ | rest], idx), do: subcommand_index(rest, idx + 1)
  defp subcommand_index(["-" <> _ | rest], idx), do: subcommand_index(rest, idx + 1)
  defp subcommand_index([sub | _], idx), do: {idx, sub}

  @doc """
  The `-c key=value` (and `--no-pager`) prefix that `cmd/2` prepends.

  Exposed for call sites that must build the argv themselves (injectable git
  seams, `System.cmd/3` wrappers under test) and for assertions.
  """
  @spec hardening_args([binary()], keyword(), keyword()) :: [binary()]
  def hardening_args(args \\ [], sys_opts \\ [], hardening \\ []) do
    hooks = Keyword.get(hardening, :hooks, :disabled)
    filters = Keyword.get(hardening, :filters, :disabled)

    # `--no-pager` also neutralizes a repo-configured `core.pager`; git already
    # skips the pager for piped output, so this is belt-and-braces only.
    base = ["--no-pager"]

    base =
      if hooks == :disabled,
        do: base ++ ["-c", "core.hooksPath=" <> @null_device],
        else: base

    # `core.fsmonitor` names a program git runs on most worktree-reading
    # commands. There is no legitimate reason for a repo we are inspecting to
    # choose it for us.
    base = base ++ ["-c", "core.fsmonitor=false"]

    if filters == :disabled do
      base ++ driver_overrides(probe_dir(args, sys_opts))
    else
      base
    end
  end

  @doc """
  A `git_fun`-style seam: `(args, cwd) -> {output, status}` with hardening applied.

  Matches the `(args, cwd)` arity used by `OptimalSystemAgent.Agent.Fleet.Finalizer`
  and friends.
  """
  @spec run(list(binary()), binary()) :: result()
  def run(args, cwd) when is_list(args) and is_binary(cwd) do
    cmd(args, cd: cwd, stderr_to_stdout: true)
  end

  # ── Executable-driver probe ───────────────────────────────────────────

  # Resolve the directory the hardening probe should run in. `:cd` wins; a
  # leading `git -C <dir>` is honoured too so `cwd.ex`-style call sites probe
  # the repo they actually target.
  defp probe_dir(args, sys_opts) do
    case Keyword.get(sys_opts, :cd) do
      dir when is_binary(dir) -> dir
      _ -> leading_dash_c_dir(args) || File.cwd!()
    end
  rescue
    _ -> "."
  end

  defp leading_dash_c_dir(["-C", dir | _]) when is_binary(dir), do: dir
  defp leading_dash_c_dir(_), do: nil

  # Blank out every executable clean/smudge/process/textconv driver the repo
  # configures. We must enumerate them first because git has no wildcard form
  # of `-c`.
  defp driver_overrides(dir) do
    case cached_drivers(dir) do
      {:ok, keys} ->
        Enum.flat_map(keys, fn key -> ["-c", key <> "="] end)

      :miss ->
        keys = probe_drivers(dir)
        put_cache(dir, keys)
        Enum.flat_map(keys, fn key -> ["-c", key <> "="] end)
    end
  end

  defp probe_drivers(dir) do
    # The probe itself must not be able to trigger the very drivers it is
    # looking for: `git config` reads config only, and we still disable hooks
    # and fsmonitor for it.
    argv =
      ["--no-pager", "-c", "core.hooksPath=" <> @null_device, "-c", "core.fsmonitor=false"] ++
        ["config", "--null", "--name-only", "--get-regexp", @executable_driver_pattern]

    case System.cmd("git", argv, cd: dir, stderr_to_stdout: false) do
      # exit 1 == "no matching keys", the overwhelmingly common case.
      {out, status} when status in [0, 1] ->
        out
        |> String.split("\0", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  rescue
    # No git binary, unreadable dir, … — hardening degrades to the static
    # overrides rather than breaking the caller.
    _ -> []
  catch
    _, _ -> []
  end

  # ── Tiny TTL cache (per directory) ────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    # Lost the create race with another process — the table exists now.
    ArgumentError -> :ok
  end

  defp cached_drivers(dir) do
    ensure_table()

    case :ets.lookup(@cache_table, dir) do
      [{^dir, keys, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, keys}, else: :miss

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp put_cache(dir, keys) do
    ensure_table()
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@cache_table, {dir, keys, expires_at})
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  # Test seam: drop the probe cache.
  def __reset_cache__ do
    ensure_table()
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    _ -> :ok
  end
end
