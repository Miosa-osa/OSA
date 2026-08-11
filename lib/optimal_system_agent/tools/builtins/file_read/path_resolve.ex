defmodule OptimalSystemAgent.Tools.Builtins.FileRead.PathResolve do
  @moduledoc """
  Unicode-tolerant path resolution and near-miss suggestions for `file_read`.

  ## Why this exists

  Two different byte sequences can name the same visible filename. `é` is either
  one codepoint (NFC, `C3 A9`) or two (NFD, `65 CC 81`). macOS's HFS+/APFS
  historically stored NFD; Linux filesystems store whatever bytes were handed to
  them; both render identically in a terminal. So a path copied out of one
  listing and pasted into another can fail to open while *looking* correct, and
  the resulting "No such file" is unfalsifiable by eye — the caller re-types the
  same string and fails again.

  `resolve/1` closes that gap: if the literal path misses, it retries the NFC
  and NFD forms, and finally scans the parent directory for an entry that is
  Unicode-equivalent to the requested basename.

  When the miss is genuine, `suggestions/2` supplies the other half: the closest
  real entries in the parent directory. "No such file" plus three real
  neighbours is a next step; "No such file" alone is a dead end.
  """

  @default_limit 3

  # Below this Jaro similarity, a "suggestion" is noise rather than a lead.
  @min_similarity 0.7

  @doc """
  Return an existing path equivalent to `path`, or `path` unchanged.

  Tries, in order: the path as given, its NFC form, its NFD form, and finally
  any entry in the parent directory whose NFC form matches the requested
  basename's NFC form. Returns `path` untouched when nothing exists, so callers
  can go on to produce a normal "does not exist" message.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(path) when is_binary(path) do
    if File.exists?(path) do
      path
    else
      Enum.find(normalized_variants(path), &File.exists?/1) || dir_scan_match(path) || path
    end
  end

  @doc """
  True when `resolved` is the same name as `requested` under Unicode normalisation.

  Used to explain a rescue in the tool's own words rather than silently
  succeeding on a path the caller did not literally type.
  """
  @spec unicode_equivalent?(String.t(), String.t()) :: boolean()
  def unicode_equivalent?(requested, resolved) do
    requested != resolved and nfc(requested) != nil and nfc(requested) == nfc(resolved)
  end

  @doc """
  Closest existing entries to `path`'s basename, within `path`'s parent directory.

  Returns `{:no_parent, dir}` when the parent directory itself cannot be listed
  (it does not exist, or is not readable) — a different fact, and a different
  next step, from "the directory is there but has nothing like that in it".
  Directories in the result are suffixed with `/` so the caller can tell at a
  glance that `dir_list` rather than `file_read` is the follow-up.
  """
  @spec suggestions(String.t(), pos_integer()) :: {:ok, [String.t()]} | {:no_parent, String.t()}
  def suggestions(path, limit \\ @default_limit) when is_binary(path) do
    dir = Path.dirname(path)
    base = Path.basename(path)

    case File.ls(dir) do
      {:ok, entries} ->
        {:ok, closest(entries, base, dir, limit)}

      {:error, _reason} ->
        {:no_parent, dir}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp closest(entries, base, dir, limit) do
    target = String.downcase(base)

    entries
    |> Enum.map(fn entry -> {entry, similarity(String.downcase(entry), target)} end)
    |> Enum.filter(fn {_entry, score} -> score >= @min_similarity end)
    |> Enum.sort_by(fn {entry, score} -> {-score, entry} end)
    |> Enum.take(limit)
    |> Enum.map(fn {entry, _score} -> decorate(dir, entry) end)
  end

  # Whole-name Jaro alone is dominated by the extension: against `reprot.txt`,
  # `empty.txt` (0.83) outranks `report.md` (0.78) purely because it ends in
  # `.txt`, which inverts what the caller actually mistyped. Averaging in the
  # stem's similarity restores the intent — the stem is the part a human gets
  # wrong — and pushes coincidental extension matches back below the threshold.
  #
  # `String.jaro_distance/2` raises on invalid UTF-8, and filenames are just
  # bytes, so a latin-1 leftover in the directory must not take the read down
  # with it.
  defp similarity(entry, target) do
    if String.valid?(entry) and String.valid?(target) do
      whole = String.jaro_distance(entry, target)
      stem = String.jaro_distance(Path.rootname(entry), Path.rootname(target))
      (whole + stem) / 2
    else
      0.0
    end
  end

  defp decorate(dir, entry) do
    if File.dir?(Path.join(dir, entry)), do: entry <> "/", else: entry
  end

  defp normalized_variants(path) do
    [nfc(path), nfd(path)]
    |> Enum.reject(&(is_nil(&1) or &1 == path))
    |> Enum.uniq()
  end

  defp dir_scan_match(path) do
    dir = Path.dirname(path)
    target = nfc(Path.basename(path))

    with true <- is_binary(target),
         {:ok, entries} <- File.ls(dir),
         entry when is_binary(entry) <- Enum.find(entries, &(nfc(&1) == target)) do
      Path.join(dir, entry)
    else
      _ -> nil
    end
  end

  defp nfc(binary) when is_binary(binary) do
    case :unicode.characters_to_nfc_binary(binary) do
      result when is_binary(result) -> result
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp nfc(_), do: nil

  defp nfd(binary) when is_binary(binary) do
    case :unicode.characters_to_nfd_binary(binary) do
      result when is_binary(result) -> result
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp nfd(_), do: nil
end
