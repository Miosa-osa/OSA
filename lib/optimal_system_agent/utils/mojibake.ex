defmodule OptimalSystemAgent.Utils.Mojibake do
  @moduledoc """
  Repairs the narrow, recognisable UTF-8-as-Latin-1 corruption produced by
  older session imports.

  The repair is deliberately conservative. It only accepts a decoding pass
  when that pass reduces known mojibake markers, so ordinary non-ASCII text is
  returned byte-for-byte unchanged.
  """

  @markers ["Ã", "Â", "â"]

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
