defmodule OptimalSystemAgent.Channels.Chunker do
  @moduledoc """
  One shared, tested splitter for outbound channel messages.

  ## Why this exists

  Every channel adapter used to carry its own copy of a "split the reply into
  chunks" routine, and they were all wrong in the same way: the size *test* and
  the size *split* were expressed in different units.

      # the bug, verbatim, from telegram.ex / slack.ex / discord.ex
      if byte_size(candidate) > @max_message_length do
        {head, tail} = String.split_at(para, @max_message_length - 10)

  `byte_size/1` counts UTF-8 bytes; `String.split_at/2` counts graphemes. For
  ASCII the two agree and the code looks fine. For CJK (3 bytes/char), emoji
  (4 bytes/codepoint), or a ZWJ emoji sequence (one grapheme, 25+ bytes) they
  diverge by 3-25x, so `head` came back several times over the provider's cap.
  The provider rejected that one chunk with a 400 and the adapter — which
  ignored per-chunk results — carried on sending the rest. The user saw a hole
  punched in the middle of the reply, which reads as the agent losing its train
  of thought.

  The rule this module enforces: **measure and split in the same unit, and make
  that unit the one the provider actually counts.**

  ## Units

    * `:bytes`     — UTF-8 bytes. What byte-framed APIs cap (WeCom, DingTalk,
      Feishu, Matrix event PDUs, signal-cli).
    * `:utf16`     — UTF-16 code units, i.e. JavaScript's `String.length`. What
      Telegram (its message-entity offsets are UTF-16), Discord, LINE and the
      JS WhatsApp bridge count. A BMP char is 1, an astral char (most emoji) is
      2, a ZWJ family sequence is 7-11.
    * `:graphemes` — Unicode extended grapheme clusters, i.e. what a human
      calls "a character".

  ## Guarantees

  For `chunk(text, limit, unit)`:

    1. Every returned chunk satisfies `measure(chunk, unit) <= limit`. The one
       unavoidable exception is a *single* grapheme cluster that is itself over
       the limit — splitting that would mangle the cluster, so it is emitted
       whole. (No real limit is small enough for this to happen; it exists so
       the function cannot loop forever.)
    2. No content is lost, duplicated, or reordered: concatenating the chunks
       reproduces the input exactly, modulo the whitespace at the split points.
       Formally `strip_ws(Enum.join(chunks)) == strip_ws(text)`.
    3. Splits prefer paragraph boundaries (`\\n\\n`), then fall back to a
       grapheme-safe hard split for a single over-long paragraph.
  """

  @type unit :: :bytes | :utf16 | :graphemes

  @doc """
  Size of `text` in `unit`.

  This is the function a caller should use to assert a chunk fits — it is the
  same one `chunk/3` splits with, which is the entire point.
  """
  @spec measure(String.t(), unit()) :: non_neg_integer()
  def measure(text, :bytes) when is_binary(text), do: byte_size(text)

  def measure(text, :graphemes) when is_binary(text), do: String.length(text)

  def measure(text, :utf16) when is_binary(text) do
    case :unicode.characters_to_binary(text, :utf8, {:utf16, :little}) do
      bin when is_binary(bin) -> div(byte_size(bin), 2)
      # Invalid UTF-8 can't be transcoded. Fall back to the byte count, which
      # over-estimates and therefore only ever splits more conservatively.
      _ -> byte_size(text)
    end
  end

  @doc """
  Split `text` into chunks that each fit within `limit` when measured in `unit`.

  See the module doc for the guarantees. Returns `[""]`-free output: an empty
  input yields `[]`.
  """
  @spec chunk(String.t(), pos_integer(), unit()) :: [String.t()]
  def chunk(text, limit, unit)
      when is_binary(text) and is_integer(limit) and limit > 0 and
             unit in [:bytes, :utf16, :graphemes] do
    cond do
      String.trim(text) == "" ->
        []

      measure(text, unit) <= limit ->
        [text]

      true ->
        text
        |> String.split("\n\n")
        |> accumulate(limit, unit, [], nil)
        # A run of blank lines can leave an all-whitespace chunk behind. Posting
        # one is a guaranteed 400 from every provider here, and it carries no
        # content, so it is dropped rather than sent.
        |> Enum.reject(&(String.trim(&1) == ""))
    end
  end

  # ── Paragraph accumulation ──────────────────────────────────────────────
  #
  # `current` is nil when no paragraph is buffered, so that we can tell "no
  # chunk started" apart from "chunk started and it happens to be empty".

  defp accumulate([], _limit, _unit, acc, nil), do: Enum.reverse(acc)

  defp accumulate([], _limit, _unit, acc, current), do: Enum.reverse([current | acc])

  defp accumulate([para | rest], limit, unit, acc, current) do
    candidate = if current == nil, do: para, else: current <> "\n\n" <> para

    cond do
      measure(candidate, unit) <= limit ->
        accumulate(rest, limit, unit, acc, candidate)

      # A buffered chunk is already full: flush it and retry this paragraph
      # against a fresh chunk.
      current != nil ->
        accumulate([para | rest], limit, unit, [current | acc], nil)

      # Nothing buffered and this single paragraph still doesn't fit, so no
      # paragraph boundary can save us. Hard split it in the measured unit.
      true ->
        {full, remainder} = hard_split(para, limit, unit)
        accumulate(rest, limit, unit, Enum.reverse(full, acc), remainder)
    end
  end

  # ── Grapheme-safe hard split ────────────────────────────────────────────
  #
  # Walks extended grapheme clusters (so a ZWJ emoji family, a flag, or a
  # base+combining-mark pair is never torn in half) and accumulates them while
  # the running size stays within `limit` *in the caller's unit*.
  #
  # Returns {complete_chunks_in_order, trailing_partial_or_nil} so the caller
  # can keep filling the trailing chunk with the next paragraph.

  defp hard_split(text, limit, unit) do
    {chunks, current, _size} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn grapheme, {chunks, current, size} ->
        g_size = measure(grapheme, unit)

        cond do
          size + g_size <= limit ->
            {chunks, [grapheme | current], size + g_size}

          # Pathological: one grapheme cluster wider than the whole limit.
          # Emit it alone rather than splitting it or looping forever.
          current == [] ->
            {[grapheme | chunks], [], 0}

          true ->
            {[join(current) | chunks], [grapheme], g_size}
        end
      end)

    trailing = if current == [], do: nil, else: join(current)
    {Enum.reverse(chunks), trailing}
  end

  defp join(reversed_graphemes), do: reversed_graphemes |> Enum.reverse() |> Enum.join()
end
