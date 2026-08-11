defmodule OptimalSystemAgent.CLI.Width do
  @moduledoc """
  Display-width arithmetic for the CLI renderers — the Elixir counterpart of the
  Rust TUI's `crate::util::fit_cols`.

  Every CLI surface that draws a bordered box or a padded column needs to know
  how many TERMINAL COLUMNS a string occupies. Three different things were being
  used for that, and all three are wrong:

    * `String.length/1` counts GRAPHEMES. A CJK ideograph or an emoji is one
      grapheme but occupies TWO columns, so a box padded this way tears its `│`
      border and every column to the right shears over by one.
    * `byte_size/1` counts BYTES, which over-measures all non-ASCII by ~3x and
      collapses the column instead.
    * Stripping only SGR (`~r/\\e\\[[0-9;]*m/`) leaves cursor-movement CSI
      sequences and OSC-8 hyperlinks in the string, where they are counted as
      visible text despite occupying zero columns.

  This module is the single source for all of it. It measures whole GRAPHEME
  CLUSTERS (never codepoints — cutting between codepoints splits emoji ZWJ
  sequences and regional-indicator flag pairs) and strips the full CSI/OSC set.

  ## Why a table here rather than a call into the Rust side

  OSA has no wcwidth/east-asian-width table anywhere in its Elixir. The
  alternative to the minimal table below is shelling out to the Rust TUI binary,
  which is rejected: these renderers run in plain-CLI contexts where no TUI
  process exists (`osa doctor`, `osa usage`, the non-interactive plan gate), a
  port round-trip per line is absurd for text layout, and it would put a new
  runtime failure mode underneath a CONSENT GATE. The table is the standard
  East-Asian-Width Wide/Fullwidth ranges plus the zero-width combining/format
  ranges — the same data every terminal library embeds.
  """

  # OSC (incl. OSC-8 hyperlinks) terminated by BEL or ST. Must run before CSI:
  # an OSC payload can contain characters a CSI pattern would match.
  @osc ~r/\e\][^\a\e]*(?:\a|\e\\)/
  # Full CSI: ESC [ <params> <intermediates> <final @-~>. SGR (`m`) is one case.
  @csi ~r/\e\[[0-?]*[ -\/]*[@-~]/
  # Two-character escapes (ESC M, ESC 7, ...).
  @simple ~r/\e[@-Z\\-_0-9]/

  # East Asian Wide + Fullwidth, and the emoji planes.
  @wide [
    0x1100..0x115F,
    0x2E80..0x303E,
    0x3041..0x33FF,
    0x3400..0x4DBF,
    0x4E00..0x9FFF,
    0xA000..0xA4CF,
    0xA960..0xA97F,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE6F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F,
    0x1F680..0x1F6FF,
    0x1F900..0x1F9FF,
    0x20000..0x3FFFD
  ]

  # Combining marks, joiners, variation selectors: zero columns of their own.
  @zero [
    0x0300..0x036F,
    0x0483..0x0489,
    0x0591..0x05BD,
    0x0610..0x061A,
    0x064B..0x065F,
    0x0670..0x0670,
    0x06D6..0x06DC,
    0x0900..0x0903,
    0x093A..0x094F,
    0x0951..0x0957,
    0x1AB0..0x1AFF,
    0x1DC0..0x1DFF,
    0x200B..0x200F,
    0x2028..0x202E,
    0x2060..0x2064,
    0x20D0..0x20FF,
    0xFE00..0xFE0F,
    0xFE20..0xFE2F,
    0xFEFF..0xFEFF,
    0xE0100..0xE01EF
  ]

  @doc """
  Remove every ANSI escape sequence — CSI (not just SGR), OSC (incl. OSC-8
  hyperlinks) and the two-character escapes.
  """
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(str) when is_binary(str) do
    str
    |> String.replace(@osc, "")
    |> String.replace(@csi, "")
    |> String.replace(@simple, "")
  end

  @doc """
  Display width of `str` in TERMINAL COLUMNS, ignoring ANSI escapes.

  Use this anywhere `String.length/1` was being used as a width.
  """
  @spec visible(String.t()) :: non_neg_integer()
  def visible(str) when is_binary(str) do
    str
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  @doc """
  Width of one grapheme CLUSTER.

  A cluster is as wide as its widest visible codepoint: `a` + a combining acute
  is one column, and an emoji ZWJ sequence is two — not two per member, which is
  what summing codepoint widths would give.
  """
  @spec grapheme_width(String.t()) :: non_neg_integer()
  def grapheme_width(g) when is_binary(g) do
    g
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, acc -> max(acc, codepoint_width(cp)) end)
  end

  defp codepoint_width(cp) when cp < 0x20 or (cp >= 0x7F and cp < 0xA0), do: 0

  defp codepoint_width(cp) do
    cond do
      in_any?(cp, @zero) -> 0
      in_any?(cp, @wide) -> 2
      true -> 1
    end
  end

  defp in_any?(cp, ranges), do: Enum.any?(ranges, &(cp in &1))

  @doc """
  Fit `str` into at most `max` display columns, appending `…` when it does not.

  Breaks on grapheme clusters, so it never splits an emoji ZWJ sequence or a
  regional-indicator flag pair in half.
  """
  @spec fit(String.t(), non_neg_integer()) :: String.t()
  def fit(str, max) when is_binary(str) and is_integer(max) do
    cond do
      visible(str) <= max -> str
      max <= 0 -> ""
      true -> take_cols(str, max - 1) <> "…"
    end
  end

  @doc "Greedily take whole grapheme clusters up to `budget` columns."
  @spec take_cols(String.t(), non_neg_integer()) :: String.t()
  def take_cols(str, budget) when is_binary(str) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      w = grapheme_width(g)

      if used + w > budget do
        {:halt, {acc, used}}
      else
        {:cont, {[g | acc], used + w}}
      end
    end)
    |> then(fn {acc, _} -> acc |> Enum.reverse() |> Enum.join() end)
  end

  @doc "Number of spaces needed to pad `str` out to `width` columns."
  @spec pad_width(String.t(), non_neg_integer()) :: non_neg_integer()
  def pad_width(str, width), do: max(width - visible(str), 0)

  @doc "Right-pad `str` with spaces so it occupies exactly `width` columns."
  @spec pad(String.t(), non_neg_integer()) :: String.t()
  def pad(str, width) do
    t = fit(str, width)
    t <> String.duplicate(" ", pad_width(t, width))
  end

  @doc "Left-pad (right-align) `str` so it occupies exactly `width` columns."
  @spec pad_start(String.t(), non_neg_integer()) :: String.t()
  def pad_start(str, width) do
    t = fit(str, width)
    String.duplicate(" ", pad_width(t, width)) <> t
  end

  @doc """
  Word-wrap `text` to `width` columns.

  Two things the previous per-file copies of this got wrong:

    * **An over-long token was emitted intact.** Splitting on whitespace and
      starting a new line with a word that does not fit means a URL, long path or
      base64 blob wider than the box blows out every border column after it.
      Tokens wider than `width` are now hard-broken on grapheme clusters.
    * **Original whitespace was discarded.** Splitting on `~r/\\s+/` normalized a
      user's indentation and alignment away. Leading indentation is preserved and
      carried onto continuation lines.
  """
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line(line, width) do
    if visible(line) <= width do
      [line]
    else
      indent = leading_indent(line)
      # A continuation indent that ate the whole line would loop forever.
      indent = if visible(indent) >= width, do: "", else: indent
      body_width = width - visible(indent)

      line
      |> String.trim_leading()
      |> split_words()
      |> Enum.flat_map(&break_token(&1, body_width))
      |> assemble(body_width)
      |> Enum.map(&(indent <> &1))
    end
  end

  defp leading_indent(line) do
    case Regex.run(~r/^[ \t]*/, line) do
      [ws] -> ws
      _ -> ""
    end
  end

  defp split_words(s), do: s |> String.split(~r/\s+/, trim: true)

  # Hard-break a single token that can never fit on a line of its own.
  defp break_token(word, width) do
    if visible(word) <= width do
      [word]
    else
      chunk(word, width, [])
    end
  end

  defp chunk("", _width, acc), do: Enum.reverse(acc)

  defp chunk(rest, width, acc) do
    head = take_cols(rest, width)
    # Guard against a zero-width head (a single grapheme wider than the whole
    # line) so this can never spin.
    head = if head == "", do: rest |> String.graphemes() |> hd(), else: head
    chunk(String.replace_prefix(rest, head, ""), width, [head | acc])
  end

  defp assemble(words, width) do
    words
    |> Enum.reduce([""], fn word, [current | rest] ->
      cond do
        current == "" -> [word | rest]
        visible(current) + 1 + visible(word) <= width -> [current <> " " <> word | rest]
        true -> [word, current | rest]
      end
    end)
    |> Enum.reverse()
  end
end
