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
  # A single UTF-8 char is at most 4 bytes → at most 4 mojibake codepoints, so a
  # trailing run longer than this is already several complete chars, not one
  # in-flight one.
  @max_moji_cps 4

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
  # the text does not end mid-sequence. The run is the last marker codepoint
  # when everything after it, to the end, is continuation-range and the whole
  # run is no longer than a single char's worth of bytes.
  defp incomplete_tail_start(cps) do
    last_marker =
      cps
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {cp, idx}, acc -> if cp in @marker_cps, do: idx, else: acc end)

    with i when is_integer(i) <- last_marker,
         after_cps = Enum.drop(cps, i + 1),
         true <- length(after_cps) < @max_moji_cps,
         true <- Enum.all?(after_cps, &continuation?/1) do
      i
    else
      _ -> nil
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
