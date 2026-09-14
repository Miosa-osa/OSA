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

  # Windows-1252 (CP1252) reverse map: codepoint => the 0x80..0x9F byte it was
  # decoded FROM. The common real-world mojibake is not pure Latin-1 — a byte in
  # 0x80..0x9F read as CP1252 becomes a PRINTABLE character (€ ' ' " " – — … •
  # etc.) whose codepoint is > 255, not a C1 control. glm/z.ai render an em-dash
  # (`E2 80 94`) this way as `â€"` = [U+00E2, U+20AC, U+201D]. The old repair only
  # mapped codepoints <= 255 back to bytes, so any CP1252 char in the run made
  # the whole re-decode fail `String.valid?/1` and the corruption survived in
  # full — the `Ã¢`/`â€"` the user saw. Mapping these back to their source byte
  # lets the run decode as one unit. This is exactly ftfy's fix.
  @cp1252 %{
    0x20AC => 0x80,
    0x201A => 0x82,
    0x0192 => 0x83,
    0x201E => 0x84,
    0x2026 => 0x85,
    0x2020 => 0x86,
    0x2021 => 0x87,
    0x02C6 => 0x88,
    0x2030 => 0x89,
    0x0160 => 0x8A,
    0x2039 => 0x8B,
    0x0152 => 0x8C,
    0x017D => 0x8E,
    0x2018 => 0x91,
    0x2019 => 0x92,
    0x201C => 0x93,
    0x201D => 0x94,
    0x2022 => 0x95,
    0x2013 => 0x96,
    0x2014 => 0x97,
    0x02DC => 0x98,
    0x2122 => 0x99,
    0x0161 => 0x9A,
    0x203A => 0x9B,
    0x0153 => 0x9C,
    0x017E => 0x9E,
    0x0178 => 0x9F
  }

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
        if cp in @marker_cps or continuation?(cp) or Map.has_key?(@cp1252, cp),
          do: {:cont, idx},
          else: {:halt, acc}
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
        is_nil(hold) ->
          nil

        # Trailing run longer than one in-flight char (> @max_moji_cps cps): it
        # is SEVERAL chars, so an incomplete char can sit at the very end. The
        # old code returned `nil` here — repair the WHOLE combined string and
        # hold nothing — but an incomplete tail makes the latin1 re-decode fail
        # `String.valid?/1` for the ENTIRE latin1 segment, so `repair/1` left
        # even the complete leading chars unrepaired (the tail poisoned the
        # segment). Hold from the run's FIRST marker instead: the prefix BEFORE
        # the run is a clean char boundary and is repaired now, and the whole run
        # is held. Holding the whole run (not a sub-slice) is deliberate — a
        # double-encoded char has NON-ADJACENT markers, so slicing to the last
        # marker could split one and re-poison the prefix. Any complete chars in
        # the held run flush on the next non-marker delta or at `flush/1`, so
        # nothing is lost.
        len - hold > @max_moji_cps ->
          hold

        true ->
          hold
      end
    end
  end

  defp continuation?(cp), do: cp >= 0x80 and cp <= 0xBF

  @spec repair(String.t()) :: String.t()
  def repair(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.chunk_by(&repairable_cp?/1)
    |> Enum.map_join(fn codepoints ->
      segment = List.to_string(codepoints)
      if repairable_cp?(hd(codepoints)), do: repair_segment(segment, 3), else: segment
    end)
  end

  # A codepoint the mojibake reversal can map back to a source byte: any Latin-1
  # byte (<= 255) or a CP1252 printable standing in for a 0x80..0x9F byte. Used to
  # chunk so a mojibake run whose continuation is a CP1252 char (`â€"`) is NOT
  # split across the <=255 boundary before it can be re-decoded as one unit.
  defp repairable_cp?(cp), do: cp <= 255 or Map.has_key?(@cp1252, cp)

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
      |> Enum.reduce_while([], fn codepoint, acc ->
        case cp_to_byte(codepoint) do
          nil -> {:halt, :not_latin1}
          byte -> {:cont, [byte | acc]}
        end
      end)

    case bytes do
      :not_latin1 -> :error
      reversed -> reversed |> Enum.reverse() |> :erlang.list_to_binary() |> valid_utf8()
    end
  end

  # Codepoint back to the byte it was mis-decoded from: a Latin-1 byte is itself;
  # a CP1252 printable maps to its 0x80..0x9F source byte; anything else is not
  # part of a mojibake run and aborts the re-decode.
  defp cp_to_byte(cp) when cp <= 255, do: cp
  defp cp_to_byte(cp), do: Map.get(@cp1252, cp)

  defp valid_utf8(candidate) do
    if String.valid?(candidate), do: {:ok, candidate}, else: :error
  end
end
