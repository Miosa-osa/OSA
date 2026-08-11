defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Messages do
  @moduledoc """
  The text `file_glob` returns when it cannot hand back a useful match list.

  ## Why this is its own module

  Same contract as `FileRead.Messages`, for the same reason: for a tool, the
  failure message *is* the feature. "No files matched pattern: **/*.ex" is a
  dead end — it does not say *where* it looked, and it collapses four completely
  different situations into one string:

    * the base directory does not exist (the caller mistyped `path`),
    * the base "directory" is actually a file,
    * the directory exists and genuinely has no match,
    * the directory has matches but they were all filtered out.

  Only the third of those means "try a different pattern". The other three mean
  "the pattern was never the problem". Every function here therefore:

    1. names the base directory that was actually searched,
    2. states the specific fact that produced the empty result,
    3. gives a concrete next step, with the tool and arguments spelled out.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.Constants
  alias OptimalSystemAgent.Tools.Builtins.FileRead.PathResolve

  @doc """
  The `path` base directory does not exist.

  This is the failure most worth separating out: a typo in `path` and a genuinely
  unmatched pattern used to be the same message, so the caller would rewrite a
  perfectly good pattern over and over against a directory that was never there.
  """
  @spec missing_base(String.t()) :: String.t()
  def missing_base(base) do
    case PathResolve.suggestions(base, Constants.max_suggestions()) do
      {:no_parent, parent} ->
        "The search base #{base} does not exist — and neither does its parent #{parent}, " <>
          "so no pattern can match anything under it. The pattern was never the problem. " <>
          "Use `dir_list` on the nearest ancestor that does exist to find the real path."

      {:ok, []} ->
        parent = Path.dirname(base)

        "The search base #{base} does not exist, and nothing in #{parent} has a similar " <>
          "name. No pattern can match under a directory that is not there. Use `dir_list` " <>
          "with `path: \"#{parent}\"` to see what is actually available, then retry " <>
          "`file_glob` with a corrected `path`."

      {:ok, names} ->
        parent = Path.dirname(base)

        "The search base #{base} does not exist. The closest existing entries in #{parent} " <>
          "are: #{Enum.join(names, ", ")}. Retry `file_glob` with `path` set to the " <>
          "corrected directory — the pattern itself was never evaluated."
    end
  end

  @doc "The `path` base is a regular file, so there is nothing to search *inside*."
  @spec base_not_a_directory(String.t()) :: String.t()
  def base_not_a_directory(base) do
    "The search base #{base} is a file, not a directory, so `file_glob` has nothing to " <>
      "walk. Use `file_read` with `path: \"#{base}\"` to read it, `file_grep` to search " <>
      "inside it, or set `path` to its directory (#{Path.dirname(base)}) and let the " <>
      "pattern select the file."
  end

  @doc "The base directory exists but cannot be listed (permissions, usually)."
  @spec base_unreadable(String.t(), atom()) :: String.t()
  def base_unreadable(base, reason) do
    "The search base #{base} exists but cannot be walked: #{:file.format_error(reason)} " <>
      "(#{inspect(reason)}). The pattern was never evaluated, so retrying it will fail " <>
      "identically. Check ownership with `shell_execute` and `ls -ld #{base}`, or search " <>
      "a directory you can read."
  end

  @doc """
  The base directory exists and is readable, and the pattern genuinely matched nothing.

  Says so explicitly — "the directory IS there" is the fact that tells the caller
  to change the pattern rather than the path — and states the dotfile and `.git`
  rules, because a caller who does not know them cannot tell a real empty result
  from a filtered one.
  """
  @spec no_matches(String.t(), String.t(), non_neg_integer(), boolean()) :: String.t()
  def no_matches(pattern, base, entry_count, git_filtered?) do
    entries =
      case entry_count do
        0 ->
          "#{base} exists and is readable, but is completely empty (0 entries), so no " <>
            "pattern can match in it. "

        n ->
          "#{base} exists and is readable and holds #{n} top-level " <>
            "#{pluralise(n, "entry", "entries")}, so the directory is not the problem — " <>
            "the pattern is. "
      end

    git_note =
      if git_filtered? do
        "Matches inside `.git/` were filtered out; include `.git` in the pattern itself " <>
          "if you meant to search the repository internals. "
      else
        ""
      end

    "No files matched pattern `#{pattern}` under #{base}. " <>
      entries <>
      "Dotfiles and dot-directories ARE searched, so a leading `.` is not why this is " <>
      "empty. " <>
      git_note <>
      "Next: use `dir_list` with `path: \"#{base}\"` to see the real names, broaden to " <>
      "`**/#{Path.basename(pattern)}` to search recursively, or use `file_grep` if you " <>
      "were looking for file *contents* rather than file names."
  end

  @doc """
  More matches exist than the result cap allows.

  Reports the true total, not just the truncated count, because "200 files found"
  and "200 of 4,312 files found" call for different next moves.
  """
  @spec truncated(non_neg_integer(), non_neg_integer(), String.t()) :: String.t()
  def truncated(shown, total, base) do
    "#{shown} of #{total} matching files (capped at #{shown}; sorted alphabetically, so " <>
      "this is a prefix of the full list, not a sample). Narrow the pattern, or set " <>
      "`path` to a subdirectory of #{base}, to see the rest."
  end

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_, _singular, plural), do: plural
end
