defmodule OptimalSystemAgent.Agent.OneLineSummary do
  @moduledoc """
  A subagent's one-line summary, derived from whatever text it produced.

  The agents panel shows one short line under a finished worker. That line is
  derived from the worker's final reply, and a reply is often several
  paragraphs of markdown. Taking the "first line" was not enough: a heading
  (`## Summary`) became the summary, and a first paragraph written as one long
  line became a 140-character fragment cut mid-word.

  The rule here is: first paragraph that carries prose (headings, fences and
  blank lines skipped; list/quote markers stripped), then its first sentence,
  then a hard clamp with an ellipsis. It never raises.
  """

  @default_max 140

  @spec from_text(String.t() | nil, pos_integer()) :: String.t()
  def from_text(text, max \\ @default_max)

  def from_text(text, max) when is_binary(text) and is_integer(max) and max > 1 do
    text
    |> first_prose_paragraph()
    |> first_sentence()
    |> clamp(max)
  rescue
    _ -> ""
  end

  def from_text(_text, _max), do: ""

  defp first_prose_paragraph(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.map(fn lines ->
      Enum.reject(lines, &(&1 == "" or heading_or_fence?(&1)))
    end)
    |> Enum.find([], &(&1 != []))
    |> paragraph_text()
    |> then(&Regex.replace(~r/\s+/u, &1, " "))
    |> String.trim()
  end

  # A list's first item is a unit of its own. A prose line continues onto the
  # next only when it looks hard-wrapped — long, and not ending a sentence —
  # so "a heading-like line\nanother line" keeps just its first line.
  @wrap_min 60

  defp paragraph_text([]), do: ""

  defp paragraph_text([first | rest]) do
    if list_item?(first) do
      strip_markers(first)
    else
      [first | rest]
      |> Enum.map(&strip_markers/1)
      |> take_wrapped([])
      |> Enum.join(" ")
    end
  end

  defp take_wrapped([], acc), do: Enum.reverse(acc)

  defp take_wrapped([line | rest], acc) do
    if String.length(line) >= @wrap_min and not Regex.match?(~r/[.!?:]$/, line),
      do: take_wrapped(rest, [line | acc]),
      else: Enum.reverse([line | acc])
  end

  defp heading_or_fence?(line), do: String.starts_with?(line, ["#", "```", "~~~"])

  defp list_item?(line), do: Regex.match?(~r/^(?:[-*+]|\d+[.)])\s+/, line)

  defp strip_markers(line) do
    line
    |> String.replace(~r/^(?:>\s*)+/, "")
    |> String.replace(~r/^(?:[-*+]|\d+[.)])\s+/, "")
    |> String.replace(~r/^\*\*(.+?)\*\*:?\s*/, "\\1: ")
    |> String.trim()
  end

  # Ends at `.`, `!` or `?` followed by whitespace and a capital letter, digit
  # or opening quote — so "e.g. the", "v1.2.3" and "3.5 hours" do not split.
  defp first_sentence(""), do: ""

  defp first_sentence(text) do
    case Regex.run(~r/^.+?[.!?](?=\s+["'(\[]?[\p{Lu}\d])/u, text) do
      [sentence] -> sentence
      _ -> text
    end
  end

  defp clamp(text, max) do
    if String.length(text) <= max do
      text
    else
      cut = String.slice(text, 0, max - 1)

      cut =
        case Regex.run(~r/^(.*\S)\s+\S*$/u, cut) do
          [_, head] when byte_size(head) > div(byte_size(cut), 2) -> head
          _ -> cut
        end

      String.trim_trailing(cut, ",;:") <> "…"
    end
  end
end
