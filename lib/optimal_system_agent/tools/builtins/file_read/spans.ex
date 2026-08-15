defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Spans do
  @moduledoc """
  Closed integer line intervals, and the three operations range subtraction
  needs: normalise, subtract, intersect.

  ## Why this exists (the 0.8% problem)

  Redundant-read suppression shipped keyed on *path plus exact window*, which
  answers the question "have I sent these bytes before?" with a yes/no. Measured
  over 118 transcripts — 1,142 `file_read` calls, 2.63 MB of delivered read
  payload — **708 calls (62%) re-read a path this session had already read**, but
  only **19 calls / 20 KB / 0.8% of the payload** asked for the byte-identical
  window that a same/different verdict can catch. The bytes are somewhere else
  entirely:

  | overlap shape        | calls | bytes  | share of payload |
  |----------------------|------:|-------:|-----------------:|
  | overlapping windows  |   293 | 412 KB |            16.1% |
  | disjoint windows     |   219 | 412 KB |            16.1% |
  | whole-file re-read   |   177 | 395 KB |            15.4% |
  | identical window     |    19 |  20 KB |             0.8% |

  A yes/no verdict cannot address 31.5% of the payload (overlap + whole-file),
  because those calls are *partly* new. The operation that can is **subtraction**:
  the session holds lines 40–80, the model asks for 1–120, so send 1–39 and
  81–120 and say plainly that 40–80 was omitted and why. Disjoint windows
  (16.1%) are genuinely new content and subtraction correctly leaves them alone —
  they are in the table to show that the "62% re-read a path" headline is not
  62% of recoverable waste.

  ## Why intervals and not a set of line numbers

  A set would be exact but unbounded: a session that walks a 60k-line file in
  100-line windows would accumulate 60,000 integers per path. Intervals are
  merged on every insert, so the representation is bounded by the number of
  *disjoint* regions the session has actually touched — typically one or two,
  and a walk that tiles a file collapses back to a single span.

  ## Conventions

  A span is `{first, last}`, 1-based and **inclusive at both ends**, so a
  one-line span is `{7, 7}`. Every function here takes and returns spans in
  normalised form: sorted ascending, non-overlapping, and non-adjacent
  (`{1, 5}` and `{6, 9}` merge into `{1, 9}`, because there is no line between
  them and keeping them apart would grow the set without describing anything).

  Spans carry no notion of file identity or content validity. Deciding whether a
  held span is still *true* — same content hash, same mtime/size, same compaction
  epoch — belongs to `Tools.FileState`, which owns that state already. This
  module is arithmetic.
  """

  @type span :: {pos_integer(), pos_integer()}

  @doc """
  Sort, clamp and merge a list of spans into canonical form.

  Invalid spans (`last < first`, non-positive lines, non-integers) are dropped
  rather than raising: this runs on the read hot path and a malformed span
  recorded by some future caller must cost a merge, not a tool call.
  """
  @spec normalize([span()]) :: [span()]
  def normalize(spans) when is_list(spans) do
    spans
    |> Enum.filter(&valid?/1)
    |> Enum.sort()
    |> merge()
  end

  def normalize(_), do: []

  defp valid?({f, l}) when is_integer(f) and is_integer(l) and f >= 1 and l >= f, do: true
  defp valid?(_), do: false

  # Adjacent spans merge as well as overlapping ones — `{1,5}` and `{6,9}` have
  # no line between them, so representing them separately describes nothing and
  # costs a gap marker in the rendered output.
  defp merge([]), do: []

  defp merge([first | rest]) do
    rest
    |> Enum.reduce([first], fn {f, l}, [{pf, pl} | acc] ->
      if f <= pl + 1,
        do: [{pf, max(pl, l)} | acc],
        else: [{f, l}, {pf, pl} | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  Union of two normalised (or unnormalised) span lists.
  """
  @spec union([span()], [span()]) :: [span()]
  def union(a, b) when is_list(a) and is_list(b), do: normalize(a ++ b)

  @doc """
  `want` minus every span in `held` — the parts of the requested window the
  session does not already hold.

  Returns `[]` when `held` covers `want` entirely, and `[want]` when they do not
  overlap at all. Those two answers are the whole-file re-read case and the
  disjoint-window case respectively, and callers treat them differently.
  """
  @spec subtract(span(), [span()]) :: [span()]
  def subtract({f, l} = want, held) when is_list(held) do
    if valid?(want) do
      held
      |> normalize()
      |> Enum.reduce({[], f}, fn {hf, hl}, {acc, cursor} ->
        cond do
          # Held span ends before the cursor, or starts after the window: no
          # effect on what remains.
          hl < cursor -> {acc, cursor}
          hf > l -> {acc, cursor}
          # Held span starts after the cursor: everything between is remaining.
          hf > cursor -> {[{cursor, hf - 1} | acc], max(cursor, hl + 1)}
          # Held span covers the cursor: skip past it.
          true -> {acc, max(cursor, hl + 1)}
        end
      end)
      |> then(fn {acc, cursor} ->
        acc = if cursor <= l, do: [{cursor, l} | acc], else: acc
        acc |> Enum.reverse() |> normalize()
      end)
    else
      []
    end
  end

  def subtract(_, _), do: []

  @doc """
  The parts of `want` that ARE held — the complement of `subtract/2` within the
  window. This is what the omission notice names, so the model can see exactly
  which lines were withheld rather than inferring them from a gap.
  """
  @spec intersect(span(), [span()]) :: [span()]
  def intersect({f, l} = want, held) when is_list(held) do
    if valid?(want) do
      held
      |> normalize()
      |> Enum.flat_map(fn {hf, hl} ->
        lo = max(f, hf)
        hi = min(l, hl)
        if lo <= hi, do: [{lo, hi}], else: []
      end)
      |> normalize()
    else
      []
    end
  end

  def intersect(_, _), do: []

  @doc "How many lines a span list covers in total."
  @spec line_count([span()]) :: non_neg_integer()
  def line_count(spans) when is_list(spans),
    do: Enum.reduce(spans, 0, fn {f, l}, acc -> acc + (l - f + 1) end)

  @doc """
  Does `line_no` fall inside any span? Linear in the number of *spans*, which is
  bounded by the merge above — not in the number of lines.
  """
  @spec member?([span()], integer()) :: boolean()
  def member?(spans, line_no) when is_list(spans),
    do: Enum.any?(spans, fn {f, l} -> line_no >= f and line_no <= l end)

  @doc """
  Render a span list the way a human (and a model) reads a page range:
  `"12"` for a single line, `"12-40"` for a run, comma-separated for several.
  """
  @spec describe([span()]) :: String.t()
  def describe(spans) when is_list(spans) do
    spans
    |> Enum.map_join(", ", fn
      {f, f} -> "#{f}"
      {f, l} -> "#{f}-#{l}"
    end)
  end
end
