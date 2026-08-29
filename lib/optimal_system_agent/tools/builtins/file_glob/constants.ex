defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename here
  propagates automatically.
  """

  @tool_name "file_glob"
  def tool_name, do: @tool_name

  @sensitive_paths [
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/id_ecdsa",
    ".ssh/id_dsa",
    ".gnupg/",
    ".aws/credentials",
    ".env",
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/master.passwd",
    ".netrc",
    ".npmrc",
    ".pypirc"
  ]
  def sensitive_paths, do: @sensitive_paths

  @max_results 200
  def max_results, do: @max_results

  @max_suggestions 3
  def max_suggestions, do: @max_suggestions

  @doc """
  Directories whose contents are noise in every ordinary search.

  Only relevant because `file_glob` walks dot-directories (`match_dot: true`).
  Without this, a plain `**/*` in any repository returns a few thousand loose
  objects under `.git/` and nothing else survives the result cap — the dotfile
  fix would have cost more than it bought. The filter is skipped whenever the
  caller names the directory in the pattern, so `.git/**` still works.

  `_build`, `deps` and `node_modules` are here for a second reason: on a real
  project these hold tens to hundreds of thousands of files (an Elixir `_build`
  is full of SYMLINKED dep dirs), and `Path.wildcard` both walks and follows
  them, so a `**`-rooted glob over a repo root walked for MINUTES and froze the
  turn. Filtering them from the result is not enough on its own — the walk is
  also hard-bounded (see `walk_timeout_ms/0`) — but it keeps a completed broad
  search readable.
  """
  @noise_dirs [".git", "_build", "deps", "node_modules"]
  def noise_dirs, do: @noise_dirs

  @doc """
  Hard ceiling on how long the directory walk may run.

  `Path.wildcard/2` walks the WHOLE tree under `path` and follows symlinks, so a
  repo root with a large symlinked `_build`/`deps` can walk for minutes and
  freeze the turn - the operator then interrupts, killing all in-flight work.
  Past this deadline the walk is killed and the tool returns actionable guidance
  ("narrow the path") instead of hanging. Override with `:file_glob_timeout_ms`.
  """
  @walk_timeout_ms 15_000
  def walk_timeout_ms do
    case Application.get_env(:optimal_system_agent, :file_glob_timeout_ms, @walk_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @walk_timeout_ms
    end
  end
end
