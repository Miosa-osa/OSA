defmodule OptimalSystemAgent.Tools.Builtins.DirList.Messages do
  @moduledoc """
  The text `dir_list` returns when it cannot hand back a normal listing.

  ## Why this is its own module

  Same contract as `FileRead.Messages`. `dir_list` had the sharpest version of
  the problem the contract exists to fix: an empty directory returned
  `{:ok, ""}` — success, with zero bytes. On the wire that is indistinguishable
  from a tool that ran and produced nothing, and the caller's only move is to
  call it again. An empty directory is a *fact about the filesystem*, and it has
  to be said out loud.

  The other three failures (`:enotdir`, `:eacces`, `:enoent`) all used to render
  as a bare errno inside "Cannot list …", which names neither the cause nor a
  next step. Each function here:

    1. names the directory,
    2. states the specific fact that stopped the listing,
    3. gives a concrete next step, with the tool and arguments spelled out.
  """

  alias OptimalSystemAgent.Tools.Builtins.DirList.Constants
  alias OptimalSystemAgent.Tools.Builtins.FileRead.PathResolve

  @doc """
  The directory exists and is readable but holds no entries.

  Returned on the success channel, mirroring `FileRead.Messages.empty_file/1`:
  an empty directory is not a failure of the listing, and the two primitives
  must not disagree about whether "there is nothing here" is an error. The
  `<dir_list notice: …>` wrapper exists so the text cannot be mistaken for a
  one-entry listing.
  """
  @spec empty_directory(String.t()) :: String.t()
  def empty_directory(display_path) do
    "<dir_list notice: #{display_path} is empty (0 entries) — this is the tool speaking, " <>
      "not a listing>\n" <>
      "The directory exists and is readable, but contains no entries at all — not even " <>
      "hidden ones (`dir_list` always includes dotfiles). This is not a listing failure " <>
      "and retrying it will return the same thing. If you expected contents: confirm the " <>
      "path with `dir_list` on its parent (#{Path.dirname(display_path)}), or check " <>
      "whether the process that populates it has actually run."
  end

  @doc """
  The path exists but is a file, not a directory (`:enotdir`).

  Worth its own message because the fix is a different *tool*, not a different
  path — the caller already has the right path.
  """
  @spec not_a_directory(String.t()) :: String.t()
  def not_a_directory(display_path) do
    "#{display_path} is a file, not a directory, so there is nothing to list. Use " <>
      "`file_read` with `path: \"#{display_path}\"` to read its contents, or `dir_list` " <>
      "with `path: \"#{Path.dirname(display_path)}\"` to list the directory that " <>
      "contains it."
  end

  @doc """
  The directory does not exist (`:enoent`).

  Offers the closest real neighbours for the same reason `file_read` does: the
  overwhelmingly common cause is a near miss, and three real names fix it in one
  step instead of a probing sequence.
  """
  @spec missing(String.t()) :: String.t()
  def missing(display_path) do
    case PathResolve.suggestions(display_path, Constants.max_suggestions()) do
      {:no_parent, parent} ->
        "#{display_path} does not exist — and neither does its parent directory #{parent}, " <>
          "so nothing under that path can be listed. Call `dir_list` on the nearest " <>
          "ancestor that does exist, or `file_glob` with " <>
          "`pattern: \"**/#{Path.basename(display_path)}\"` to find where it actually lives."

      {:ok, []} ->
        parent = Path.dirname(display_path)

        "#{display_path} does not exist, and nothing in #{parent} has a similar name. " <>
          "Call `dir_list` with `path: \"#{parent}\"` to see what is actually there, or " <>
          "`file_glob` with `pattern: \"**/#{Path.basename(display_path)}\"` to search " <>
          "more widely."

      {:ok, names} ->
        parent = Path.dirname(display_path)

        "#{display_path} does not exist. The closest existing entries in #{parent} are: " <>
          "#{Enum.join(names, ", ")}. Retry `dir_list` with the corrected path (entries " <>
          "ending in `/` are directories; for the others use `file_read`)."
    end
  end

  @doc "The directory exists but cannot be read (`:eacces` and friends)."
  @spec unreadable(String.t(), atom()) :: String.t()
  def unreadable(display_path, :eacces) do
    "#{display_path} exists but you do not have permission to list it (eacces). Retrying " <>
      "will fail identically. Inspect the directory's ownership and mode with " <>
      "`shell_execute` and `ls -ld #{display_path}`, or list a directory you can read."
  end

  def unreadable(display_path, reason) do
    "Cannot list #{display_path}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
      "This is a filesystem-level failure, not a bad path, so retrying the same call " <>
      "will fail the same way. Use `shell_execute` with `ls -ld #{display_path}` to see " <>
      "the directory's real state."
  end
end
