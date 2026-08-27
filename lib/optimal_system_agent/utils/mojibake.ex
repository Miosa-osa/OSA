defmodule OptimalSystemAgent.Utils.Mojibake do
  @moduledoc """
  Repairs the narrow, recognisable UTF-8-as-Latin-1 corruption produced by
  older session imports.

  The repair is deliberately conservative. It only accepts a decoding pass
  when that pass reduces known mojibake markers, so ordinary non-ASCII text is
  returned byte-for-byte unchanged.
  """

  @markers ["Ã", "Â", "â"]

  # Codepoints a UTF-8 lead byte lands on when its bytes are misread as Latin-1:
  # Â (0xC2), Ã (0xC3), â (0xE2). A mojibake run is one of these followed by the
  # original char's continuation bytes, which decode to the 0x80..0xBF range.
  @marker_cps [0xC2, 0xC3, 0xE2]
  # A single UTF-8 char is at most 4 bytes. A DOUBLY-mojibaked char (the form
  # some providers emit — e.g. glm/z.ai renders an em-dash as `Ã¢Â\x80Â\x94`)
  # re-encodes each of those bytes again, so one in-flight char can be up to 8
  # mojibake codepoints. A trailing run longer than this is already several
  # complete chars, not one in-flight one.
  @max_moji_cps 8

  @doc """
  Stateful repair for a STREAM of deltas: `{text_to_emit, carry_for_next_delta}`.

  Per-delta `repair/1` fails when a mojibake sequence is split across two
  streamed chunks — a delta ending in a lone `â` cannot be re-decoded, so the
  corruption survives. This holds back a possibly-incomplete trailing mojibake
  run (a marker codepoint followed only by continuation-range codepoints, up to
  one char's worth) and prepends it to the next delta, so the sequence is only
  repaired once it is whole. Non-mojibake text is never held.

  Thread `carry` through the stream (start `""`) and call `flush/1` at the end
  to emit whatever remained held.
  """
  @spec repair_stream(String.t(), String.t()) :: {String.t(), String.t()}
  def repair_stream(carry, delta) when is_binary(carry) and is_binary(delta) do
    combined = carry <> delta

    case incomplete_tail_start(String.to_charlist(combined)) do
      nil ->
        {repair(combined), ""}

      i ->
        {safe, tail} = combined |> String.to_charlist() |> Enum.split(i)
        {repair(List.to_string(safe)), List.to_string(tail)}
    end
  end

  @doc "Repair and return whatever `repair_stream/2` was still holding."
  @spec flush(String.t()) :: String.t()
  def flush(carry) when is_binary(carry), do: repair(carry)

  # Index where a possibly-incomplete trailing mojibake run begins, or nil when
  # the text does not end mid-sequence.
  #
  # A mojibake char — single OR double-encoded — is a contiguous run of marker
  # and continuation codepoints. The earlier version anchored on the LAST marker
  # and held only from there; that splits a double-encoded char (whose markers
  # sit at non-adjacent positions, e.g. `[C3 A2][C2 80][C2 94]`) into two halves
  # that can never be rejoined across deltas, so each half emitted as broken
  # mojibake. Instead: find the maximal trailing run of marker/continuation
  # codepoints and hold from its FIRST marker (leading continuation bytes belong
  # to an already-emitted char). `repair/1` can then re-decode the whole run as
  # one unit once a non-mojibake codepoint (or stream end) proves it complete.
  defp incomplete_tail_start(cps) do
    len = length(cps)

    # Start of the maximal trailing run of marker-or-continuation codepoints
    # (`len` when the text does not end in one).
    run_start =
      cps
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce_while(len, fn {cp, idx}, acc ->
        # Halt with the ACCUMULATOR (the start of the trailing run seen so far),
        # not `len` — returning `len` here discarded the run and made the hold-back
        # dead whenever the mojibake was preceded by ordinary text ("hello â…").
        if cp in @marker_cps or continuation?(cp), do: {:cont, idx}, else: {:halt, acc}
      end)

    if run_start == len do
      nil
    else
      hold =
        cps
        |> Enum.drop(run_start)
        |> Enum.with_index(run_start)
        |> Enum.find_value(fn {cp, idx} -> if cp in @marker_cps, do: idx, else: nil end)

      cond do
        # No marker in the trailing run — only orphaned continuation bytes whose
        # marker was already emitted; nothing to hold.
        is_nil(hold) -> nil
        # Too long to be a single in-flight char — treat as complete and repair now.
        len - hold > @max_moji_cps -> nil
        true -> hold
      end
    end
  end

  defp continuation?(cp), do: cp >= 0x80 and cp <= 0xBF

  @spec repair(String.t()) :: String.t()
  def repair(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.chunk_by(&(&1 <= 255))
    |> Enum.map_join(fn codepoints ->
      segment = List.to_string(codepoints)
      if hd(codepoints) <= 255, do: repair_segment(segment, 3), else: segment
    end)
  end

  defp repair_segment(text, 0), do: text

  defp repair_segment(text, passes_left) do
    before = marker_count(text)

    with true <- before > 0,
         {:ok, candidate} <- latin1_bytes_as_utf8(text),
         true <- marker_count(candidate) < before do
      repair_segment(candidate, passes_left - 1)
    else
      _ -> text
    end
  end

  defp marker_count(text) do
    Enum.reduce(@markers, 0, fn marker, total ->
      total + length(:binary.matches(text, marker))
    end)
  end

  defp latin1_bytes_as_utf8(text) do
    bytes =
      text
      |> String.to_charlist()
      |> Enum.reduce_while([], fn
        codepoint, acc when codepoint <= 255 -> {:cont, [codepoint | acc]}
        _codepoint, _acc -> {:halt, :not_latin1}
      end)

    case bytes do
      :not_latin1 -> :error
      reversed -> reversed |> Enum.reverse() |> :erlang.list_to_binary() |> valid_utf8()
    end
  end

  defp valid_utf8(candidate) do
    if String.valid?(candidate), do: {:ok, candidate}, else: :error
  end
end
