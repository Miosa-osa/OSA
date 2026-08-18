defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors the pattern established by `FileRead.Constants`.
  Other tools' prompts reference `tool_name/0` so a rename propagates
  automatically.
  """

  @tool_name "file_grep"
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

  # Generous but bounded — grep can return large outputs when searching
  # broad directories with context lines enabled.
  @max_output_bytes 100_000
  def max_output_bytes, do: @max_output_bytes

  # How many files the pure-Elixir fallback will read in one search.
  #
  # Was 500, applied to a full-tree `Path.wildcard/1` result with `Enum.take/2`
  # and never mentioned in the output. On the NodeBB workspace under `bench/`
  # that meant 500 of 54,905 files — 0.9% of the tree, stopping inside `build/`
  # without ever reaching `src/` — reported as "No matches found."
  #
  # 20,000 is affordable now for two reasons that did not hold before: the walk
  # prunes dependency and build directories at the DIRECTORY level, so the
  # budget is spent on source; and when the cap does bite the result says so, so
  # a partial search is no longer indistinguishable from an exhaustive one.
  @max_fallback_files 20_000
  def max_fallback_files, do: @max_fallback_files

  @default_max_results 50
  def default_max_results, do: @default_max_results

  # Deadline for ONE ripgrep subprocess. Not a bound on the tool call, the turn,
  # or the session — only on how long a single `rg` may produce nothing before
  # it is declared wedged and killed.
  #
  # 120s matches `shell_execute`'s own subprocess bound, and is one to two orders
  # of magnitude above a real search: a cold `rg` over a large monorepo is single-
  # digit seconds. Anything past this is not a slow search, it is `rg` blocked on
  # a FIFO, a stalled network mount, or a `/proc` pseudo-file — cases where it
  # would never return at all.
  #
  # Override with `:file_grep_timeout_ms`; `:infinity` restores the old
  # unbounded behaviour for an operator who wants it.
  @ripgrep_timeout_ms 120_000
  def ripgrep_timeout_ms do
    case Application.get_env(:optimal_system_agent, :file_grep_timeout_ms, @ripgrep_timeout_ms) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @ripgrep_timeout_ms
    end
  end
end
