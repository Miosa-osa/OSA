defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher do
  @moduledoc """
  Codex V4A-style fuzzy matching for `file_edit`.

  `String.replace/4` is exact-only, so an edit fails whenever the model's
  `old_string` drifts from the file by nothing more than line endings or
  trailing whitespace. This module runs a 3-stage cascade, stopping at the
  first stage that yields a match:

    1. **exact**          — `old_string` is a verbatim substring (fast path,
                            identical semantics to the previous implementation).
    2. **line endings**   — compare line-by-line after normalising CRLF/CR to LF,
                            so `\\r\\n` vs `\\n` drift no longer breaks the match.
    3. **whitespace**     — additionally trim leading/trailing whitespace on each
                            line.

  The fuzzy stages put back what they ignored in order to match. A match found
  by ignoring `\\r` re-emits the region's own line ending; a match found by
  ignoring indentation shifts `new_string` by the difference between the file's
  actual indentation and the indentation `old_string` claimed, preserving the
  relative indentation inside `new_string`.

  Both of those used to be dropped: `new_string` was spliced in exactly as
  supplied, which put LF lines inside a CRLF file and wrote the model's
  indentation over the file's — silently re-indenting code no edit had asked to
  touch, which is a syntax change in Python and diff noise everywhere else.

  Fuzzy stages only ever splice out a contiguous run of whole lines, so they can
  never partially match inside a line. `replace_all: false` requires the match to
  be unique (returns `{:error, :ambiguous, count}` otherwise); `replace_all: true`
  replaces every non-overlapping match.

  When those three stages all miss, control passes to
  `FuzzyMatcher` (P0 #3) — the nine-strategy opencode cascade (block-anchor
  Levenshtein, whitespace/indent/escape normalization, trimmed-boundary,
  context-aware, multi-occurrence) plus the disproportionate-match guard. Exact
  still wins first: this module's fast path is unchanged, and the cascade is only
  ever a fallback after an exact substring miss.

  ## Return
    * `{:ok, new_content, count, stage}` — `stage` is `:exact | :line_endings |
      :whitespace` for the local stages, or a `FuzzyMatcher` strategy atom
      (`:block_anchor`, `:context_aware`, …) when the deeper cascade matched.
    * `{:error, :not_found}`
    * `{:error, :ambiguous, count}`
    * `{:error, :disproportionate}` — a fuzzy candidate matched a span far larger
      than `old_string`; refuse rather than clobber (from `FuzzyMatcher`).
    * `{:error, {:replace_all_approximate, strategy}}` — `replace_all: true` was
      requested but only an APPROXIMATE strategy matched. A fuzzy candidate is a
      suggestion about one site, not a licence to rewrite every site that
      resembles it, so the cascade refuses rather than corrupt unrelated regions
      (from `FuzzyMatcher` — see its moduledoc).
  """

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.FuzzyMatcher

  @type stage :: :exact | :line_endings | :whitespace | FuzzyMatcher.strategy()

  @spec replace(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t(), non_neg_integer(), stage()}
          | {:error, :not_found}
          | {:error, :ambiguous, non_neg_integer()}
          | {:error, :disproportionate}
          | {:error, {:replace_all_approximate, FuzzyMatcher.strategy()}}
  def replace(content, old, new, replace_all) do
    if String.contains?(content, old) do
      count = count_occurrences(content, old)

      if count > 1 and not replace_all do
        {:error, :ambiguous, count}
      else
        {:ok, String.replace(content, old, new, global: replace_all), count, :exact}
      end
    else
      fuzzy(content, old, new, replace_all)
    end
  end

  # ── Fuzzy line-based cascade ──────────────────────────────────────────

  defp fuzzy(content, old, new, replace_all) do
    content_lines = String.split(content, "\n")
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")

    [:line_endings, :whitespace]
    |> Enum.reduce_while({:error, :not_found}, fn stage, acc ->
      norm = normalizer(stage)
      starts = match_starts(content_lines, old_lines, norm)

      case starts do
        [] ->
          {:cont, acc}

        [_ | _] = matches ->
          count = length(matches)

          if count > 1 and not replace_all do
            {:halt, {:error, :ambiguous, count}}
          else
            new_content =
              splice(content_lines, matches, length(old_lines), new_lines, old_lines, stage)

            {:halt, {:ok, new_content, count, stage}}
          end
      end
    end)
    |> case do
      # Local line-endings/whitespace stages found nothing: hand off to the
      # deeper nine-strategy cascade (P0 #3). Its result — including the
      # disproportionate-match refusal and its own ambiguity check — is returned
      # verbatim.
      {:error, :not_found} -> FuzzyMatcher.replace(content, old, new, replace_all)
      other -> other
    end
  end

  # Normalisation applied to each line before comparison, per stage.
  #
  # Only a TRAILING `\r` is stripped. `String.replace(&1, "\r", "")` removed
  # every `\r` anywhere in the line, so a line with an embedded carriage return
  # (progress-bar output in a fixture, a `"\r"` inside a string literal) was
  # compared with that character silently deleted, and could match an
  # `old_string` that does not describe it.
  defp normalizer(:line_endings), do: &String.replace_trailing(&1, "\r", "")

  defp normalizer(:whitespace),
    do: &(&1 |> String.replace_trailing("\r", "") |> String.trim())

  # Return the 0-based start indices of every NON-OVERLAPPING window in
  # `content_lines` whose normalised lines equal the normalised `old_lines`.
  defp match_starts(content_lines, old_lines, norm) do
    window = length(old_lines)
    normalized_old = Enum.map(old_lines, norm)
    max_start = length(content_lines) - window

    if max_start < 0 do
      []
    else
      0..max_start
      |> Enum.reduce({[], -1}, fn i, {acc, last_end} ->
        if i <= last_end do
          {acc, last_end}
        else
          slice = content_lines |> Enum.slice(i, window) |> Enum.map(norm)

          if slice == normalized_old do
            {[i | acc], i + window - 1}
          else
            {acc, last_end}
          end
        end
      end)
      |> elem(0)
      |> Enum.reverse()
    end
  end

  # Replace each matched window (highest index first, so earlier indices stay
  # valid) with `new_lines`, then rejoin.
  #
  # The replacement lines are ADAPTED to the region they land in. Both stages
  # matched by ignoring something; writing the model's raw lines back in put
  # that something back wrong:
  #
  #   * `:line_endings` matched a CRLF file against an LF `old_string` and then
  #     spliced in the model's LF-only lines, leaving a run of LF lines inside
  #     an otherwise-CRLF file. Every editor, and `git diff`, then shows the
  #     whole hunk as changed, and a second edit of the same region no longer
  #     matches the file it just wrote.
  #
  #   * `:whitespace` matched by trimming indentation, so it fires precisely
  #     when the model's indentation differs from the file's — and then wrote
  #     the model's indentation over the file's, silently re-indenting code that
  #     the edit never asked to touch (fatal in Python, noise everywhere else).
  #     The whole region is shifted by the difference between the file's actual
  #     indentation and what the model believed it to be, which preserves the
  #     RELATIVE indentation inside `new_string`.
  defp splice(content_lines, starts, window, new_lines, old_lines, stage) do
    starts
    |> Enum.sort(:desc)
    |> Enum.reduce(content_lines, fn start, lines ->
      before = Enum.slice(lines, 0, start)
      matched = Enum.slice(lines, start, window)
      rest = Enum.slice(lines, (start + window)..-1//1) || []

      replacement =
        new_lines
        |> reindent(stage, matched, old_lines)
        |> match_line_endings(matched)

      before ++ replacement ++ rest
    end)
    |> Enum.join("\n")
  end

  # Shift every replacement line by (file indent − old_string indent), taken
  # from the first line of each. Only the `:whitespace` stage can disagree
  # about indentation; the other stages compared it exactly.
  defp reindent(new_lines, :whitespace, matched, old_lines) do
    delta = indent_of(List.first(matched)) - indent_of(List.first(old_lines))

    cond do
      delta == 0 -> new_lines
      delta > 0 -> Enum.map(new_lines, &shift_right(&1, delta))
      true -> Enum.map(new_lines, &shift_left(&1, -delta))
    end
  end

  defp reindent(new_lines, _stage, _matched, _old_lines), do: new_lines

  defp indent_of(nil), do: 0

  defp indent_of(line) do
    trimmed = String.trim_leading(line)
    if trimmed == "", do: 0, else: String.length(line) - String.length(trimmed)
  end

  # A blank line stays blank rather than becoming trailing whitespace.
  defp shift_right(line, n) do
    if String.trim(line) == "", do: line, else: String.duplicate(" ", n) <> line
  end

  defp shift_left(line, n) do
    if String.trim(line) == "" do
      line
    else
      removable = min(n, indent_of(line))
      String.slice(line, removable..-1//1)
    end
  end

  # Give the replacement the line ending the region it replaces actually used.
  defp match_line_endings(new_lines, matched) do
    if Enum.any?(matched, &String.ends_with?(&1, "\r")) do
      Enum.map(new_lines, fn line ->
        if String.ends_with?(line, "\r"), do: line, else: line <> "\r"
      end)
    else
      new_lines
    end
  end

  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end
end
