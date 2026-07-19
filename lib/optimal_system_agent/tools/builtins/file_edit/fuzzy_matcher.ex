defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.FuzzyMatcher do
  @moduledoc """
  Multi-strategy fuzzy edit cascade for `file_edit` (P0 #3 in `docs/steal-list.md`).

  A faithful Elixir port of opencode's `tool/edit.ts` replacer cascade (sourced in
  turn from cline / gemini-cli). Where `Matcher` runs OSA's original
  exact → line-endings → whitespace stages, this module supplies the *deeper*
  fallback: a chain of nine text-matching strategies tried in order until exactly
  one region of the file matches, so an `old_string` that has drifted from disk by
  reindentation, escaping, whitespace-collapse, or a mangled interior still lands.

  ## The nine strategies (tried in this order)

    1. `simple`                — verbatim substring (identity; already handled by
                                 the exact fast path when reached via `Matcher`).
    2. `line_trimmed`          — per-line match after trimming each line's ends.
    3. `block_anchor`          — first/last line as anchors; the interior is scored
                                 with Levenshtein similarity (accept ≥ 0.65).
    4. `whitespace_normalized` — collapse every run of whitespace to one space.
    5. `indentation_flexible`  — strip the common leading indent, then compare.
    6. `escape_normalized`     — unescape `\\n \\t \\r \\' \\" \\\` \\\\ \\$` before comparing.
    7. `trimmed_boundary`      — match after trimming the whole block's boundary.
    8. `context_aware`         — first/last anchors + ≥50% interior line agreement.
    9. `multi_occurrence`      — every verbatim occurrence (drives `replace_all`).

  ## Guarantees (identical to opencode + OSA policy)

    * **Uniqueness.** With `replace_all: false` a strategy's candidate is only
      applied when it occurs *exactly once* in the file. A found-but-ambiguous
      candidate never silently wins — the cascade keeps searching and, if nothing
      unique is ever found, returns `{:error, :ambiguous, count}`.
    * **Disproportionate-match guard.** Before applying any candidate, reject it
      when the matched span is much larger than `old_string` (see
      `disproportionate?/2`) — this stops an anchor pair from swallowing a giant
      unrelated block. Returns `{:error, :disproportionate}`.
    * **Not found.** If no strategy produces any occurring candidate, returns
      `{:error, :not_found}`.

  ## Return

    * `{:ok, new_content, count, strategy}` — `strategy` is one of the atoms above.
    * `{:error, :not_found}`
    * `{:error, :ambiguous, count}`
    * `{:error, :disproportionate}`
  """

  @type strategy ::
          :simple
          | :line_trimmed
          | :block_anchor
          | :whitespace_normalized
          | :indentation_flexible
          | :escape_normalized
          | :trimmed_boundary
          | :context_aware
          | :multi_occurrence

  # Block-anchor / context similarity acceptance threshold (Levenshtein-derived).
  @similarity_threshold 0.65

  @strategies [
    :simple,
    :line_trimmed,
    :block_anchor,
    :whitespace_normalized,
    :indentation_flexible,
    :escape_normalized,
    :trimmed_boundary,
    :context_aware,
    :multi_occurrence
  ]

  @doc "The ordered list of strategy atoms the cascade runs."
  @spec strategies() :: [strategy()]
  def strategies, do: @strategies

  # ── Public entry ──────────────────────────────────────────────────────

  @spec replace(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t(), non_neg_integer(), strategy()}
          | {:error, :not_found}
          | {:error, :ambiguous, non_neg_integer()}
          | {:error, :disproportionate}
  def replace(content, old, new, replace_all) do
    run(@strategies, content, old, new, replace_all, {false, 0})
  end

  # ── Cascade driver ────────────────────────────────────────────────────

  # state = {found_any_candidate?, best_ambiguous_count}
  defp run([], _content, _old, _new, _replace_all, {true, amb}), do: {:error, :ambiguous, amb}
  defp run([], _content, _old, _new, _replace_all, {false, _}), do: {:error, :not_found}

  defp run([strategy | rest], content, old, new, replace_all, state) do
    candidates =
      strategy
      |> candidates(content, old)
      |> Enum.reject(&(&1 == ""))

    case try_candidates(candidates, content, old, new, replace_all) do
      {:done, new_content, count} ->
        {:ok, new_content, count, strategy}

      :disproportionate ->
        {:error, :disproportionate}

      {:continue, delta} ->
        run(rest, content, old, new, replace_all, merge_state(state, delta))
    end
  end

  # Walk one strategy's candidates. First candidate that both occurs and (unless
  # replace_all) occurs uniquely wins. The disproportionate guard fires on the
  # first occurring candidate regardless of uniqueness (mirrors opencode).
  defp try_candidates([], _content, _old, _new, _replace_all), do: {:continue, {false, 0}}

  defp try_candidates([search | rest], content, old, new, replace_all) do
    count = occurrences(content, search)

    cond do
      count == 0 ->
        try_candidates(rest, content, old, new, replace_all)

      disproportionate?(search, old) ->
        :disproportionate

      replace_all ->
        {:done, String.replace(content, search, new, global: true), count}

      count == 1 ->
        {:done, String.replace(content, search, new, global: false), 1}

      true ->
        # Found, but not unique. Remember it and keep looking for a unique match.
        case try_candidates(rest, content, old, new, replace_all) do
          {:continue, {_found?, amb}} -> {:continue, {true, max(amb, count)}}
          other -> other
        end
    end
  end

  defp merge_state({f1, a1}, {f2, a2}), do: {f1 or f2, max(a1, a2)}

  # ── Disproportionate-match guard (port of isDisproportionateMatch) ────

  @doc """
  True when `search` is so much larger than `old` that applying it would almost
  certainly clobber unintended content. Refuse rather than guess.
  """
  @spec disproportionate?(String.t(), String.t()) :: boolean()
  def disproportionate?(search, old) do
    old_lines = old |> String.split("\n") |> length()
    search_lines = search |> String.split("\n") |> length()

    cond do
      search_lines >= max(old_lines + 3, old_lines * 2) ->
        true

      old_lines == 1 ->
        false

      true ->
        st = old |> String.trim() |> String.length()
        ss = search |> String.trim() |> String.length()
        ss > max(st + 500, st * 4)
    end
  end

  # ── Strategy dispatch ─────────────────────────────────────────────────

  @doc "Return the candidate substrings a given strategy proposes for `find`."
  @spec candidates(strategy(), String.t(), String.t()) :: [String.t()]
  def candidates(:simple, _content, find), do: [find]
  def candidates(:line_trimmed, content, find), do: line_trimmed(content, find)
  def candidates(:block_anchor, content, find), do: block_anchor(content, find)
  def candidates(:whitespace_normalized, content, find), do: whitespace_normalized(content, find)
  def candidates(:indentation_flexible, content, find), do: indentation_flexible(content, find)
  def candidates(:escape_normalized, content, find), do: escape_normalized(content, find)
  def candidates(:trimmed_boundary, content, find), do: trimmed_boundary(content, find)
  def candidates(:context_aware, content, find), do: context_aware(content, find)
  def candidates(:multi_occurrence, content, find), do: multi_occurrence(content, find)

  # ── Strategy implementations ──────────────────────────────────────────

  @doc "Verbatim substring (identity strategy)."
  @spec simple(String.t(), String.t()) :: [String.t()]
  def simple(_content, find), do: [find]

  @doc "Per-line match after trimming each line's boundary whitespace."
  @spec line_trimmed(String.t(), String.t()) :: [String.t()]
  def line_trimmed(content, find) do
    orig = String.split(content, "\n")
    search = find |> String.split("\n") |> drop_trailing_empty()
    window = length(search)
    max_start = length(orig) - window

    if window == 0 or max_start < 0 do
      []
    else
      trimmed_search = Enum.map(search, &String.trim/1)

      0..max_start
      |> Enum.reduce([], fn i, acc ->
        slice = orig |> Enum.slice(i, window)

        if Enum.map(slice, &String.trim/1) == trimmed_search do
          [Enum.join(slice, "\n") | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()
    end
  end

  @doc "First/last line anchors with a Levenshtein-scored interior (≥ 0.65)."
  @spec block_anchor(String.t(), String.t()) :: [String.t()]
  def block_anchor(content, find) do
    orig = String.split(content, "\n")
    search0 = String.split(find, "\n")

    if length(search0) < 3 do
      []
    else
      search = drop_trailing_empty(search0)
      sbs = length(search)
      t = List.to_tuple(orig)
      n = tuple_size(t)
      first = search |> List.first() |> String.trim()
      last = search |> List.last() |> String.trim()
      max_delta = max(1, trunc(:math.floor(sbs * 0.25)))

      candidates =
        0..(n - 1)//1
        |> Enum.reduce([], fn i, acc ->
          if String.trim(elem(t, i)) == first do
            case first_anchor(t, i + 2, last, n) do
              nil ->
                acc

              j ->
                if abs(j - i + 1 - sbs) <= max_delta, do: [{i, j} | acc], else: acc
            end
          else
            acc
          end
        end)
        |> Enum.reverse()

      case candidates do
        [] -> []
        [one] -> best_block(orig, search, [one], sbs)
        many -> best_block(orig, search, many, sbs)
      end
    end
  end

  # Pick the highest-similarity anchor block; emit it if it clears the threshold.
  # (For a single candidate this reduces to a plain threshold check, matching
  # opencode's single/multi split which computes the same similarity either way.)
  defp best_block(orig, search, candidates, sbs) do
    {best, best_sim} =
      Enum.reduce(candidates, {nil, -1.0}, fn {i, j}, {b, bs} ->
        sim = middle_similarity(orig, search, i, sbs, j - i + 1)
        if sim > bs, do: {{i, j}, sim}, else: {b, bs}
      end)

    if best && best_sim >= @similarity_threshold do
      {i, j} = best
      [orig |> Enum.slice(i, j - i + 1) |> Enum.join("\n")]
    else
      []
    end
  end

  # Average per-line similarity over the interior lines (anchors excluded).
  # Empty (both-blank) line pairs are skipped but the divisor stays lines_to_check,
  # exactly as opencode accumulates it.
  defp middle_similarity(orig, search, start, sbs, abs_size) do
    lines_to_check = min(sbs - 2, abs_size - 2)

    if lines_to_check <= 0 do
      1.0
    else
      ot = List.to_tuple(orig)
      st = List.to_tuple(search)
      upper = min(sbs - 1, abs_size - 1) - 1

      sum =
        1..upper//1
        |> Enum.reduce(0.0, fn j, acc ->
          o = ot |> elem(start + j) |> String.trim()
          s = st |> elem(j) |> String.trim()
          max_len = max(String.length(o), String.length(s))

          if max_len == 0 do
            acc
          else
            acc + (1 - levenshtein(o, s) / max_len)
          end
        end)

      sum / lines_to_check
    end
  end

  @doc "Match after collapsing every run of whitespace to a single space."
  @spec whitespace_normalized(String.t(), String.t()) :: [String.t()]
  def whitespace_normalized(content, find) do
    nfind = normalize_ws(find)
    lines = String.split(content, "\n")

    single =
      Enum.flat_map(lines, fn line ->
        cond do
          normalize_ws(line) == nfind ->
            [line]

          nfind != "" and String.contains?(normalize_ws(line), nfind) ->
            case ws_substring(find, line) do
              nil -> []
              m -> [m]
            end

          true ->
            []
        end
      end)

    find_lines = String.split(find, "\n")

    multi =
      if length(find_lines) > 1 do
        window = length(find_lines)
        max_start = length(lines) - window

        if max_start < 0 do
          []
        else
          0..max_start
          |> Enum.reduce([], fn i, acc ->
            block = lines |> Enum.slice(i, window) |> Enum.join("\n")
            if normalize_ws(block) == nfind, do: [block | acc], else: acc
          end)
          |> Enum.reverse()
        end
      else
        []
      end

    single ++ multi
  end

  defp normalize_ws(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # Recover the exact substring of `line` that whitespace-normalizes to `find`.
  defp ws_substring(find, line) do
    words = find |> String.trim() |> String.split(~r/\s+/, trim: true)

    if words == [] do
      nil
    else
      pattern = words |> Enum.map(&Regex.escape/1) |> Enum.join("\\s+")

      with {:ok, re} <- Regex.compile(pattern),
           [m | _] <- Regex.run(re, line) do
        m
      else
        _ -> nil
      end
    end
  end

  @doc "Match after stripping the block's common leading indentation."
  @spec indentation_flexible(String.t(), String.t()) :: [String.t()]
  def indentation_flexible(content, find) do
    nfind = remove_indentation(find)
    content_lines = String.split(content, "\n")
    find_lines = String.split(find, "\n")
    window = length(find_lines)
    max_start = length(content_lines) - window

    if max_start < 0 do
      []
    else
      0..max_start
      |> Enum.reduce([], fn i, acc ->
        block = content_lines |> Enum.slice(i, window) |> Enum.join("\n")
        if remove_indentation(block) == nfind, do: [block | acc], else: acc
      end)
      |> Enum.reverse()
    end
  end

  defp remove_indentation(text) do
    lines = String.split(text, "\n")
    non_empty = Enum.filter(lines, fn l -> String.trim(l) != "" end)

    if non_empty == [] do
      text
    else
      min_indent = non_empty |> Enum.map(&indent_length/1) |> Enum.min()

      lines
      |> Enum.map(fn l ->
        if String.trim(l) == "", do: l, else: String.slice(l, min_indent, String.length(l))
      end)
      |> Enum.join("\n")
    end
  end

  defp indent_length(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, ws] -> String.length(ws)
      _ -> 0
    end
  end

  @doc "Match after unescaping backslash sequences in `find`."
  @spec escape_normalized(String.t(), String.t()) :: [String.t()]
  def escape_normalized(content, find) do
    unescaped = unescape(find)
    direct = if String.contains?(content, unescaped), do: [unescaped], else: []

    lines = String.split(content, "\n")
    find_lines = String.split(unescaped, "\n")
    window = length(find_lines)
    max_start = length(lines) - window

    blocks =
      if max_start < 0 do
        []
      else
        0..max_start
        |> Enum.reduce([], fn i, acc ->
          block = lines |> Enum.slice(i, window) |> Enum.join("\n")
          if unescape(block) == unescaped, do: [block | acc], else: acc
        end)
        |> Enum.reverse()
      end

    direct ++ blocks
  end

  defp unescape(str) do
    Regex.replace(~r/\\(n|t|r|'|"|`|\\|\n|\$)/, str, fn _full, ch ->
      case ch do
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        "'" -> "'"
        "\"" -> "\""
        "`" -> "`"
        "\\" -> "\\"
        "\n" -> "\n"
        "$" -> "$"
        _ -> "\\" <> ch
      end
    end)
  end

  @doc "Match after trimming the whole block's boundary whitespace."
  @spec trimmed_boundary(String.t(), String.t()) :: [String.t()]
  def trimmed_boundary(content, find) do
    trimmed = String.trim(find)

    if trimmed == find do
      # Already trimmed — nothing this strategy can add.
      []
    else
      direct = if String.contains?(content, trimmed), do: [trimmed], else: []

      lines = String.split(content, "\n")
      find_lines = String.split(find, "\n")
      window = length(find_lines)
      max_start = length(lines) - window

      blocks =
        if max_start < 0 do
          []
        else
          0..max_start
          |> Enum.reduce([], fn i, acc ->
            block = lines |> Enum.slice(i, window) |> Enum.join("\n")
            if String.trim(block) == trimmed, do: [block | acc], else: acc
          end)
          |> Enum.reverse()
        end

      direct ++ blocks
    end
  end

  @doc "First/last anchors plus ≥50% agreement on the interior lines."
  @spec context_aware(String.t(), String.t()) :: [String.t()]
  def context_aware(content, find) do
    find_lines0 = String.split(find, "\n")

    if length(find_lines0) < 3 do
      []
    else
      find_lines = drop_trailing_empty(find_lines0)
      content_lines = String.split(content, "\n")
      ct = List.to_tuple(content_lines)
      ft = List.to_tuple(find_lines)
      n = tuple_size(ct)
      fl = length(find_lines)
      first = find_lines |> List.first() |> String.trim()
      last = find_lines |> List.last() |> String.trim()

      0..(n - 1)//1
      |> Enum.flat_map(fn i ->
        if String.trim(elem(ct, i)) == first do
          case first_anchor(ct, i + 2, last, n) do
            nil ->
              []

            j ->
              block_len = j - i + 1

              if block_len == fl and context_ratio_ok?(ct, ft, i, block_len) do
                [content_lines |> Enum.slice(i, block_len) |> Enum.join("\n")]
              else
                []
              end
          end
        else
          []
        end
      end)
    end
  end

  # ≥50% of the interior lines (trimmed) must agree; a block with no non-empty
  # interior lines passes vacuously (matches opencode's totalNonEmptyLines === 0).
  defp context_ratio_ok?(ct, ft, i, block_len) do
    if block_len <= 2 do
      true
    else
      {matching, total} =
        1..(block_len - 2)//1
        |> Enum.reduce({0, 0}, fn k, {m, tot} ->
          bl = ct |> elem(i + k) |> String.trim()
          fl = ft |> elem(k) |> String.trim()

          cond do
            String.length(bl) == 0 and String.length(fl) == 0 -> {m, tot}
            bl == fl -> {m + 1, tot + 1}
            true -> {m, tot + 1}
          end
        end)

      total == 0 or matching / total >= 0.5
    end
  end

  @doc "Every verbatim occurrence of `find` (drives `replace_all`)."
  @spec multi_occurrence(String.t(), String.t()) :: [String.t()]
  def multi_occurrence(content, find) do
    List.duplicate(find, occurrences(content, find))
  end

  # ── Shared helpers ────────────────────────────────────────────────────

  # First index j >= from with trim(t[j]) == anchor, or nil. Uses //1 so an empty
  # search range (from > n-1) never descends into a reversed range.
  defp first_anchor(t, from, anchor, n) do
    if from > n - 1 do
      nil
    else
      Enum.reduce_while(from..(n - 1)//1, nil, fn j, _acc ->
        if String.trim(elem(t, j)) == anchor, do: {:halt, j}, else: {:cont, nil}
      end)
    end
  end

  defp drop_trailing_empty(list) do
    case List.last(list) do
      "" -> Enum.drop(list, -1)
      _ -> list
    end
  end

  defp occurrences(_content, ""), do: 0

  defp occurrences(content, search) do
    (content |> String.split(search) |> length()) - 1
  end

  # Classic Levenshtein edit distance over graphemes (rolling single row).
  @spec levenshtein(String.t(), String.t()) :: non_neg_integer()
  def levenshtein(a, a), do: 0
  def levenshtein("", b), do: String.length(b)
  def levenshtein(a, ""), do: String.length(a)

  def levenshtein(a, b) do
    bs = String.graphemes(b)
    prev = Enum.to_list(0..length(bs))

    a
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(prev, fn {ca, i}, prev_row ->
      levenshtein_row(ca, bs, prev_row, i)
    end)
    |> List.last()
  end

  defp levenshtein_row(ca, bs, prev_row, i) do
    # prev_row has length(bs)+1 entries; zip into {diag, up} pairs for each column.
    pairs = Enum.zip(prev_row, tl(prev_row))

    {cur_rev, _left} =
      bs
      |> Enum.zip(pairs)
      |> Enum.reduce({[i], i}, fn {cb, {diag, up}}, {acc, left} ->
        cost = if ca == cb, do: 0, else: 1
        val = min(min(left + 1, up + 1), diag + cost)
        {[val | acc], val}
      end)

    Enum.reverse(cur_rev)
  end
end
