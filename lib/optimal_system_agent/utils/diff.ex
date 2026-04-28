defmodule OptimalSystemAgent.Utils.Diff do
  @moduledoc """
  Unified diff generation for file operations.

  Produces unified diff format with context lines, suitable for both
  terminal display (ANSI-colored) and SSE event payloads (plain text).
  """

  @context_lines 3

  @doc """
  Generate a unified diff between old and new content for a given file path.

  Returns `{diff_text, stats}` where stats is `%{additions: n, deletions: n}`.
  """
  def unified(old_content, new_content, path)
      when is_binary(old_content) and is_binary(new_content) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    hunks = compute_hunks(old_lines, new_lines)

    if hunks == [] do
      {"", %{additions: 0, deletions: 0}}
    else
      header = "--- a/#{path}\n+++ b/#{path}"
      hunk_text = Enum.map(hunks, &format_hunk/1) |> Enum.join("\n")
      diff_text = header <> "\n" <> hunk_text

      stats = compute_stats(hunks)
      {diff_text, stats}
    end
  end

  @doc """
  Generate diff for a new file (all additions).
  """
  def for_new_file(content, path) do
    lines = String.split(content, "\n")
    additions = Enum.map(lines, fn l -> "+#{l}" end) |> Enum.join("\n")

    diff_text = "--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@\n#{additions}"
    stats = %{additions: length(lines), deletions: 0}
    {diff_text, stats}
  end

  @doc """
  Compute addition and deletion counts from diff text.
  """
  def stats(diff_text) when is_binary(diff_text) do
    lines = String.split(diff_text, "\n")

    additions =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "+") and not String.starts_with?(l, "+++")
      end)

    deletions =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "-") and not String.starts_with?(l, "---")
      end)

    %{additions: additions, deletions: deletions}
  end

  @doc """
  Format diff text with ANSI colors for terminal display.
  """
  def format_ansi(diff_text) when is_binary(diff_text) do
    diff_text
    |> String.split("\n")
    |> Enum.map(&colorize_line/1)
    |> Enum.join("\n")
  end

  # ── Private: Hunk Computation ────────────────────────────────────────

  # Simple diff algorithm using longest common subsequence approach.
  # Groups changes into hunks with context lines.
  defp compute_hunks(old_lines, new_lines) do
    # Use List.myers_difference for efficient diff
    edits = List.myers_difference(old_lines, new_lines)

    # Convert edits to indexed change list
    {changes, _old_idx, _new_idx} =
      Enum.reduce(edits, {[], 0, 0}, fn
        {:eq, lines}, {acc, oi, ni} ->
          eq_entries =
            Enum.with_index(lines)
            |> Enum.map(fn {l, i} ->
              {:eq, oi + i, ni + i, l}
            end)

          {acc ++ eq_entries, oi + length(lines), ni + length(lines)}

        {:del, lines}, {acc, oi, ni} ->
          del_entries =
            Enum.with_index(lines)
            |> Enum.map(fn {l, i} ->
              {:del, oi + i, nil, l}
            end)

          {acc ++ del_entries, oi + length(lines), ni}

        {:ins, lines}, {acc, oi, ni} ->
          ins_entries =
            Enum.with_index(lines)
            |> Enum.map(fn {l, i} ->
              {:ins, nil, ni + i, l}
            end)

          {acc ++ ins_entries, oi, ni + length(lines)}
      end)

    # Group into hunks with context
    group_into_hunks(changes)
  end

  defp group_into_hunks(changes) do
    # Find change regions (non-:eq entries) and expand with context
    indexed = Enum.with_index(changes)
    change_indices = for {{type, _, _, _}, idx} <- indexed, type != :eq, do: idx

    if change_indices == [] do
      []
    else
      # Merge nearby changes into hunk regions
      regions = merge_regions(change_indices, length(changes))

      Enum.map(regions, fn {start_idx, end_idx} ->
        # Expand with context lines
        ctx_start = max(start_idx - @context_lines, 0)
        ctx_end = min(end_idx + @context_lines, length(changes) - 1)

        hunk_entries = Enum.slice(changes, ctx_start..ctx_end)

        # Compute hunk header line numbers
        first_old = find_first_line(:old, hunk_entries, ctx_start)
        first_new = find_first_line(:new, hunk_entries, ctx_start)
        old_count = Enum.count(hunk_entries, fn {t, _, _, _} -> t in [:eq, :del] end)
        new_count = Enum.count(hunk_entries, fn {t, _, _, _} -> t in [:eq, :ins] end)

        %{
          header: "@@ -#{first_old + 1},#{old_count} +#{first_new + 1},#{new_count} @@",
          lines:
            Enum.map(hunk_entries, fn
              {:eq, _, _, l} -> " #{l}"
              {:del, _, _, l} -> "-#{l}"
              {:ins, _, _, l} -> "+#{l}"
            end)
        }
      end)
    end
  end

  defp merge_regions(indices, total_len) do
    # Merge change indices that are within 2*context_lines of each other
    gap = @context_lines * 2

    indices
    |> Enum.reduce([], fn idx, acc ->
      case acc do
        [{start, last} | rest] when idx - last <= gap ->
          [{start, idx} | rest]

        _ ->
          [{idx, idx} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {s, e} -> {s, min(e, total_len - 1)} end)
  end

  defp find_first_line(:old, entries, fallback) do
    case Enum.find(entries, fn {t, oi, _, _} -> t in [:eq, :del] and oi != nil end) do
      {_, oi, _, _} -> oi
      nil -> fallback
    end
  end

  defp find_first_line(:new, entries, fallback) do
    case Enum.find(entries, fn {t, _, ni, _} -> t in [:eq, :ins] and ni != nil end) do
      {_, _, ni, _} -> ni
      nil -> fallback
    end
  end

  defp format_hunk(%{header: header, lines: lines}) do
    header <> "\n" <> Enum.join(lines, "\n")
  end

  defp compute_stats(hunks) do
    Enum.reduce(hunks, %{additions: 0, deletions: 0}, fn %{lines: lines}, acc ->
      adds = Enum.count(lines, &String.starts_with?(&1, "+"))
      dels = Enum.count(lines, &String.starts_with?(&1, "-"))
      %{additions: acc.additions + adds, deletions: acc.deletions + dels}
    end)
  end

  # ── Private: ANSI Coloring ──────────────────────────────────────────

  defp colorize_line("+" <> _ = line), do: IO.ANSI.green() <> line <> IO.ANSI.reset()
  defp colorize_line("-" <> _ = line), do: IO.ANSI.red() <> line <> IO.ANSI.reset()
  defp colorize_line("@@" <> _ = line), do: IO.ANSI.cyan() <> line <> IO.ANSI.reset()
  defp colorize_line("---" <> _ = line), do: IO.ANSI.faint() <> line <> IO.ANSI.reset()
  defp colorize_line("+++" <> _ = line), do: IO.ANSI.faint() <> line <> IO.ANSI.reset()
  defp colorize_line(line), do: IO.ANSI.faint() <> line <> IO.ANSI.reset()
end
