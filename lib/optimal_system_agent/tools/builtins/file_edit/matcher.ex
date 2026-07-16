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
                            line. Indentation stays *significant* for the output:
                            the matched region of the ORIGINAL file is replaced,
                            and `new_string` is inserted exactly as supplied, so
                            no reflow or de-indentation is applied.

  Fuzzy stages only ever splice out a contiguous run of whole lines, so they can
  never partially match inside a line. `replace_all: false` requires the match to
  be unique (returns `{:error, :ambiguous, count}` otherwise); `replace_all: true`
  replaces every non-overlapping match.

  ## Return
    * `{:ok, new_content, count, stage}` — `stage` is `:exact | :line_endings | :whitespace`
    * `{:error, :not_found}`
    * `{:error, :ambiguous, count}`
  """

  @type stage :: :exact | :line_endings | :whitespace

  @spec replace(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t(), non_neg_integer(), stage()}
          | {:error, :not_found}
          | {:error, :ambiguous, non_neg_integer()}
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

    Enum.reduce_while([:line_endings, :whitespace], {:error, :not_found}, fn stage, acc ->
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
            new_content = splice(content_lines, matches, length(old_lines), new_lines)
            {:halt, {:ok, new_content, count, stage}}
          end
      end
    end)
  end

  # Normalisation applied to each line before comparison, per stage.
  defp normalizer(:line_endings), do: &String.replace(&1, "\r", "")
  defp normalizer(:whitespace), do: &(&1 |> String.replace("\r", "") |> String.trim())

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
  defp splice(content_lines, starts, window, new_lines) do
    starts
    |> Enum.sort(:desc)
    |> Enum.reduce(content_lines, fn start, lines ->
      before = Enum.slice(lines, 0, start)
      rest = Enum.slice(lines, (start + window)..-1//1) || []
      before ++ new_lines ++ rest
    end)
    |> Enum.join("\n")
  end

  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end
end
