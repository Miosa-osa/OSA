defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Subtraction do
  @moduledoc """
  The decision half of range subtraction: given the window a caller asked for
  and the lines the session already holds, should any of it be withheld — and is
  withholding it actually worth doing?

  `Spans` answers *what* the remainder is. This module answers *whether to send
  the remainder instead of the window*, which is a different question with three
  guards on it, none of them arithmetic.

  ## Guard 1: the saving must exceed the explanation

  Withholding is not free. It costs a header naming the omission (~330 bytes)
  plus a marker per hole (~70 bytes). A read whose held overlap is four lines
  would spend 400 bytes to save 200 — the same false economy the byte-identical
  notice already guards against, where a 607-byte notice was measured replacing
  a 732-byte read.

  So the omitted lines are priced against the markers they would cost, using the
  window's own measured byte size rather than the file's — for a windowed read of
  a large file those differ by orders of magnitude — and subtraction declines
  unless it clears the overhead by `@min_net_saving`.

  ## Guard 2: three holes is a different file

  The complement of `k` held spans inside a window is up to `k + 1` spans. A
  result cut into six pieces is technically complete and practically unreadable:
  the model has to reassemble the file from the transcript to reason about it,
  and the measured behaviour when a read is hard to interpret is another read.

  `@max_holes` caps it at 2. Past that the window comes back whole. This is a
  judgement about legibility, not correctness — every value here is safe, and
  the cap trades a little of the 31.5% for results that stay readable.

  ## Guard 3: nothing new means nothing sent

  When the held set covers the window entirely, there is no remainder to send
  and the answer is the existing byte-identical notice (`{:all_held, omitted}`)
  rather than a subtracted read with no content in it. That path is how the
  whole-file re-read after a full read gets handled, and it is the reason
  subtraction subsumes the 0.8% identical-window case rather than sitting beside
  it.

  ## On subtracting a WHOLE-FILE re-read specifically

  This is 15.4% of the measured payload and the case most worth stating an
  opinion about, because the complement of a mid-file holding is **two disjoint
  spans** and returning them looks, at first, like handing back a file with a
  hole in it.

  It is still the right answer, for one reason: the alternative is not "a clean
  whole file", it is "the whole file, most of which is already three screens up
  in the same context". The model is not choosing between a complete view and a
  fragmented one; it is choosing between one fragmented delivery and two
  complete copies of the same lines. The second costs more context and creates
  the ambiguity of two identical blocks with no statement of which is current.

  What makes the fragmented delivery safe is that it is **self-describing**:
  every delivered line carries its own file line number, the header names both
  what is present and what is not, and each hole is marked in place. A model
  that reads `39` then `81` with a marker between them knows exactly what it has.
  Guard 2 is what keeps that true — the argument holds for two holes and stops
  holding somewhere around six.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Messages
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Spans

  # Measured against the real message bodies rather than guessed: the header is
  # ~330 bytes and each gap marker ~70. Deliberately a slight OVER-estimate, so
  # a subtraction that only just clears the bar is declined rather than taken —
  # the same direction of error the rest of this tool takes.
  @header_overhead 340
  @gap_overhead 80

  # Net bytes a subtraction must save, after its own overhead, to be worth
  # taking. Below this the transcript churn buys nothing and the model pays a
  # legibility cost for it.
  @min_net_saving 200

  # See "Guard 2" above.
  @max_holes 2

  @type span :: Spans.span()
  @type plan ::
          :full
          | {:all_held, [span()]}
          | {:partial, deliver :: [span()], omitted :: [span()]}

  @doc """
  Decide what to do with `want` given `held`, where `window_bytes` is the size
  of the result the caller would otherwise receive.

  Returns:

    * `:full` — send the window as-is. The default whenever there is nothing
      held, nothing worth omitting, or the result would be too fragmented.
    * `{:all_held, omitted}` — the caller already holds every line of the
      window; answer with the unchanged-notice and record `omitted` as still
      held.
    * `{:partial, deliver, omitted}` — send only `deliver`, naming `omitted`.
  """
  @spec plan(span(), [span()], non_neg_integer(), keyword()) :: plan()
  def plan(want, held, window_bytes, opts \\ [])

  def plan(_want, [], _window_bytes, _opts), do: :full

  def plan({first, last} = want, held, window_bytes, opts)
      when is_integer(first) and is_integer(last) and first <= last do
    omitted = Spans.intersect(want, held)
    deliver = Spans.subtract(want, held)

    cond do
      omitted == [] ->
        :full

      # Nothing new to send — but the notice that says so is itself ~330 bytes,
      # and substituting it for a window smaller than that is the exact false
      # economy `read_status/3`'s own byte guard exists to prevent (measured: a
      # 607-byte notice replacing a 732-byte read). The guard has to be repeated
      # here because subtraction reaches this case by a different route — a
      # window covered by OTHER windows, which the byte-identical check never
      # sees.
      deliver == [] and window_bytes > Messages.unchanged_notice_overhead() ->
        {:all_held, omitted}

      deliver == [] ->
        :full

      length(omitted) > @max_holes ->
        :full

      worth_it?(want, omitted, deliver, window_bytes, opts) ->
        {:partial, deliver, omitted}

      true ->
        :full
    end
  end

  def plan(_want, _held, _window_bytes, _opts), do: :full

  @doc """
  Byte overhead a subtraction with `hole_count` holes would add. Public so the
  ablation harness can price the mechanism against the same numbers the decision
  uses rather than against a second copy of them.
  """
  @spec overhead(non_neg_integer()) :: non_neg_integer()
  def overhead(hole_count) when is_integer(hole_count) and hole_count >= 0,
    do: @header_overhead + @gap_overhead * hole_count

  # Estimate the omitted bytes by the omitted lines' share of the window. Exact
  # per-line accounting is available (the caller holds the lines) but not worth
  # threading: the decision only has to be right about ORDER of magnitude, and
  # the guard is one-sided — an over-estimate takes a subtraction that saves
  # slightly less than expected, an under-estimate declines one, and both leave
  # the content correct.
  defp worth_it?({first, last}, omitted, deliver, window_bytes, opts) do
    window_lines = last - first + 1

    if window_lines <= 0 or window_bytes <= 0 do
      false
    else
      omitted_bytes = div(window_bytes * Spans.line_count(omitted), window_lines)

      # A whole-file read is delivered as raw content with no line numbers. The
      # moment part of it is withheld it MUST be numbered — a hole in unnumbered
      # text is unreadable — so subtracting a whole-file read pays ~7 bytes on
      # every line it does deliver. Measured: on a 200-line file of `row N`
      # lines, omitting 120 of them saved 954 bytes and the numbering cost 560,
      # for a net loss of 101 bytes and a table row that read as a saving in
      # tokens while being a loss in bytes. Charging it here is what makes the
      # short-line whole-file case decline instead of quietly costing.
      render_cost = Keyword.get(opts, :per_delivered_line, 0) * Spans.line_count(deliver)

      omitted_bytes - overhead(length(omitted)) - render_cost >= @min_net_saving
    end
  end
end
