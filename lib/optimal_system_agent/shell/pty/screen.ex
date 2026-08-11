defmodule OptimalSystemAgent.Shell.Pty.Screen do
  @moduledoc """
  A pragmatic terminal screen model — a bounded character grid plus scrollback.

  This is deliberately NOT a full alacritty-grade emulator (that is out of
  scope for pure Elixir). It is a line/grid model that interprets *enough*
  ANSI/VT to make `screen/0` return readable text for the common cases an agent
  drives: shells, REPLs, installer prompts, and cursor-addressed TUIs.

  ## What it interprets

    * Printable text (UTF-8), with auto-wrap at the right margin.
    * `\\r` (CR), `\\n` (LF, scrolls at the bottom), `\\b` (BS), `\\t` (tab, stops of 8).
    * `CSI H` / `CSI r;cH` / `CSI f`   — cursor position (1-based).
    * `CSI A/B/C/D`                    — cursor up/down/forward/back (n).
    * `CSI G` / `CSI d`                — cursor to column / row.
    * `CSI J` (0/1/2)                  — erase in display (below/above/all).
    * `CSI K` (0/1/2)                  — erase in line (right/left/all).
    * `CSI m` (SGR)                    — colors/styles are parsed and DROPPED.
    * `CSI ?..h/l` (private modes)     — consumed and ignored (e.g. alt-screen,
                                         cursor visibility, bracketed paste).
    * `ESC ] ... BEL|ST` (OSC)         — consumed and ignored (window titles).
    * Other single-char ESC and unknown CSI — consumed and ignored.

  ## What it does NOT do (honest limitations)

    * No colors/attributes in the rendered text (SGR is stripped).
    * No scroll-region (`CSI r`), no insert/delete-line/char, no tab-clear.
    * Alt-screen switch is ignored (it renders onto the same grid), so a
      full-screen curses app that relies on the alternate buffer may leave
      residue. It stays *readable*, just not pixel-faithful.
    * Double-width / combining characters count as one cell.

  Bytes that split an escape sequence across `feed/2` calls are preserved in
  `pending` and reparsed on the next feed.
  """

  @default_scrollback 2_000

  defstruct rows: 24,
            cols: 80,
            # grid: list of `rows` maps, each %{col_index => grapheme}
            grid: nil,
            cur_row: 0,
            cur_col: 0,
            scrollback: [],
            max_scrollback: @default_scrollback,
            pending: ""

  @type t :: %__MODULE__{}

  @doc "Create a blank screen of `cols` x `rows`."
  @spec new(pos_integer(), pos_integer(), keyword()) :: t()
  def new(cols, rows, opts \\ []) do
    %__MODULE__{
      rows: rows,
      cols: cols,
      grid: blank_grid(rows),
      max_scrollback: Keyword.get(opts, :max_scrollback, @default_scrollback)
    }
  end

  @doc "Feed a chunk of raw PTY output, mutating the grid. Returns the new screen."
  @spec feed(t(), binary()) :: t()
  def feed(screen, bytes) when is_binary(bytes) do
    process(%{screen | pending: ""}, screen.pending <> bytes)
  end

  @doc "Render the visible screen as plain text (trailing blank lines trimmed)."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = s) do
    s.grid
    |> Enum.map(&render_row(&1, s.cols))
    |> trim_trailing_blank_lines()
    |> Enum.join("\n")
  end

  @doc "Cursor position as a 1-based `%{row:, col:}` map (VT convention)."
  @spec cursor(t()) :: %{row: pos_integer(), col: pos_integer()}
  def cursor(%__MODULE__{cur_row: r, cur_col: c}), do: %{row: r + 1, col: c + 1}

  @doc "Scrollback history (oldest first). `count` limits to the most recent N lines."
  @spec scrollback(t(), non_neg_integer() | :all) :: [String.t()]
  def scrollback(%__MODULE__{scrollback: sb}, :all), do: Enum.reverse(sb)

  def scrollback(%__MODULE__{scrollback: sb}, count) when is_integer(count) do
    sb |> Enum.take(count) |> Enum.reverse()
  end

  @doc "Resize the grid. Content is preserved top-left; rows added/removed at the bottom."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = s, cols, rows) do
    grid =
      cond do
        rows == s.rows -> s.grid
        rows < s.rows -> Enum.take(s.grid, rows)
        true -> s.grid ++ blank_grid(rows - s.rows)
      end

    %{
      s
      | cols: cols,
        rows: rows,
        grid: grid,
        cur_row: min(s.cur_row, rows - 1),
        cur_col: min(s.cur_col, cols - 1)
    }
  end

  # ── Parser state machine ───────────────────────────────────────────────

  # A partial escape at end-of-buffer is stashed in `pending` for the next feed.
  defp process(s, ""), do: s

  # ESC — could be CSI (\e[), OSC (\e]), or a single-char escape.
  defp process(s, "\e" <> rest) do
    cond do
      rest == "" ->
        %{s | pending: "\e"}

      String.starts_with?(rest, "[") ->
        parse_csi(s, binary_part(rest, 1, byte_size(rest) - 1))

      String.starts_with?(rest, "]") ->
        parse_osc(s, binary_part(rest, 1, byte_size(rest) - 1))

      # Single-char escapes (charset select, etc.) — drop the next byte.
      #
      # This drops one BYTE, matched byte-wise on purpose. It used to be
      # `<<_ignored::utf8, tail::binary>> = ...`, a hard pattern match that
      # raised MatchError — killing the PTY session process and its buffered
      # scrollback — whenever the byte after ESC was not a valid UTF-8 lead
      # byte. Every ESC-introduced single-char escape (charset select `ESC(B`,
      # `ESC=`, `ESC>`, `ESC7/8`, …) is ASCII, so there is no codepoint here
      # worth decoding, and a garbage byte must not be able to crash the
      # decoder.
      true ->
        <<_ignored, tail::binary>> = rest
        process(s, tail)
    end
  end

  defp process(s, "\r" <> rest), do: process(%{s | cur_col: 0}, rest)
  defp process(s, "\n" <> rest), do: process(line_feed(s), rest)
  defp process(s, "\t" <> rest), do: process(tab(s), rest)
  defp process(s, "\b" <> rest), do: process(%{s | cur_col: max(s.cur_col - 1, 0)}, rest)
  # Bell / other C0 we ignore.
  defp process(s, <<7, rest::binary>>), do: process(s, rest)

  defp process(s, <<cp::utf8, rest::binary>>) when cp >= 0x20 do
    process(put_char(s, <<cp::utf8>>), rest)
  end

  # A multi-byte character split across a `feed/2` boundary. The clause above
  # could not decode it because the continuation bytes are in the NEXT chunk,
  # and the catch-all below would consume its bytes one at a time and drop the
  # character silently. `pending` previously only ever held a partial ESCAPE
  # sequence, so every character straddling a chunk boundary was lost.
  # Stash it instead and finish decoding on the next feed.
  defp process(s, <<lead, _::binary>> = buf) when lead >= 0xC0 and lead < 0xF8 do
    if partial_utf8?(buf) do
      %{s | pending: buf}
    else
      <<_c, rest::binary>> = buf
      process(s, rest)
    end
  end

  # Any remaining C0 control we don't model — skip it.
  defp process(s, <<_c, rest::binary>>), do: process(s, rest)

  # True when `buf` is the START of one multi-byte character and nothing else:
  # a lead byte, fewer bytes than that lead announces, and continuation bytes
  # the whole way. Anything else is malformed and must not be stashed (a
  # stashed non-prefix would be re-prepended forever and wedge the decoder).
  defp partial_utf8?(<<lead, rest::binary>>) do
    byte_size(rest) + 1 < utf8_seq_len(lead) and
      rest_all_continuation?(rest)
  end

  defp rest_all_continuation?(<<>>), do: true

  defp rest_all_continuation?(<<b, rest::binary>>) when b >= 0x80 and b < 0xC0,
    do: rest_all_continuation?(rest)

  defp rest_all_continuation?(_), do: false

  defp utf8_seq_len(lead) when lead < 0xE0, do: 2
  defp utf8_seq_len(lead) when lead < 0xF0, do: 3
  defp utf8_seq_len(_lead), do: 4

  # ── CSI (\e[ ... final) ────────────────────────────────────────────────

  # Grab the parameter/intermediate bytes up to the final byte (0x40..0x7E).
  defp parse_csi(s, buf) do
    case Regex.run(~r/^([0-9;?<>=!]*)([ -\/]*)([@-~])/, buf, return: :index) do
      [{0, full_len}, {p_start, p_len}, _inter, {f_start, 1}] ->
        params = binary_part(buf, p_start, p_len)
        final = binary_part(buf, f_start, 1)
        rest = binary_part(buf, full_len, byte_size(buf) - full_len)
        process(apply_csi(s, params, final), rest)

      _ ->
        # Incomplete CSI at end of buffer — stash for the next feed (bounded).
        if byte_size(buf) < 64 do
          %{s | pending: "\e[" <> buf}
        else
          # Runaway/garbage — drop the "\e[" and resume so we can't wedge.
          process(s, buf)
        end
    end
  end

  defp apply_csi(s, params, final) do
    # Private-mode sequences (?25h, ?1049h, ?2004h, …) — consumed, no grid change.
    if String.starts_with?(params, "?") do
      s
    else
      nums = parse_params(params)

      case final do
        "H" -> cursor_to(s, arg(nums, 0, 1), arg(nums, 1, 1))
        "f" -> cursor_to(s, arg(nums, 0, 1), arg(nums, 1, 1))
        "A" -> %{s | cur_row: max(s.cur_row - arg(nums, 0, 1), 0)}
        "B" -> %{s | cur_row: min(s.cur_row + arg(nums, 0, 1), s.rows - 1)}
        "C" -> %{s | cur_col: min(s.cur_col + arg(nums, 0, 1), s.cols - 1)}
        "D" -> %{s | cur_col: max(s.cur_col - arg(nums, 0, 1), 0)}
        "G" -> %{s | cur_col: clamp(arg(nums, 0, 1) - 1, 0, s.cols - 1)}
        "d" -> %{s | cur_row: clamp(arg(nums, 0, 1) - 1, 0, s.rows - 1)}
        "J" -> erase_display(s, arg(nums, 0, 0))
        "K" -> erase_line(s, arg(nums, 0, 0))
        # SGR (colors/styles) and everything else we don't model: ignore.
        _ -> s
      end
    end
  end

  # ── OSC (\e] ... BEL | ST) ─────────────────────────────────────────────

  defp parse_osc(s, buf) do
    cond do
      # Terminated by BEL.
      (idx = :binary.match(buf, <<7>>)) != :nomatch ->
        {pos, _} = idx
        process(s, binary_part(buf, pos + 1, byte_size(buf) - pos - 1))

      # Terminated by ST (ESC \).
      (idx = :binary.match(buf, "\e\\")) != :nomatch ->
        {pos, _} = idx
        process(s, binary_part(buf, pos + 2, byte_size(buf) - pos - 2))

      # Unterminated — stash (bounded) for the next feed.
      byte_size(buf) < 512 ->
        %{s | pending: "\e]" <> buf}

      true ->
        process(s, buf)
    end
  end

  # ── Grid operations ────────────────────────────────────────────────────

  defp put_char(s, grapheme) do
    s =
      if s.cur_col >= s.cols do
        # Auto-wrap to the next line first.
        line_feed(%{s | cur_col: 0})
      else
        s
      end

    grid = update_cell(s.grid, s.cur_row, s.cur_col, grapheme)
    %{s | grid: grid, cur_col: s.cur_col + 1}
  end

  defp line_feed(s) do
    if s.cur_row + 1 >= s.rows do
      # Scroll: push the top row into scrollback, append a blank at the bottom.
      [top | rest] = s.grid
      sb = push_scrollback(s, render_row(top, s.cols))
      %{s | grid: rest ++ [blank_row()], scrollback: sb}
    else
      %{s | cur_row: s.cur_row + 1}
    end
  end

  defp tab(s) do
    next = min((div(s.cur_col, 8) + 1) * 8, s.cols - 1)
    %{s | cur_col: next}
  end

  defp erase_display(s, 0) do
    # From cursor to end of screen.
    grid =
      s.grid
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        cond do
          idx < s.cur_row -> row
          idx == s.cur_row -> clear_from(row, s.cur_col)
          true -> blank_row()
        end
      end)

    %{s | grid: grid}
  end

  defp erase_display(s, 1) do
    # From start of screen to cursor.
    grid =
      s.grid
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        cond do
          idx > s.cur_row -> row
          idx == s.cur_row -> clear_to(row, s.cur_col)
          true -> blank_row()
        end
      end)

    %{s | grid: grid}
  end

  defp erase_display(s, _all), do: %{s | grid: blank_grid(s.rows)}

  defp erase_line(s, 0),
    do: %{s | grid: update_row(s.grid, s.cur_row, &clear_from(&1, s.cur_col))}

  defp erase_line(s, 1), do: %{s | grid: update_row(s.grid, s.cur_row, &clear_to(&1, s.cur_col))}

  defp erase_line(s, _all),
    do: %{s | grid: update_row(s.grid, s.cur_row, fn _ -> blank_row() end)}

  defp cursor_to(s, row1, col1) do
    %{s | cur_row: clamp(row1 - 1, 0, s.rows - 1), cur_col: clamp(col1 - 1, 0, s.cols - 1)}
  end

  # ── Row/cell primitives (a row is %{col => grapheme}) ──────────────────

  defp blank_grid(rows), do: for(_ <- 1..rows, do: blank_row())
  defp blank_row, do: %{}

  defp update_cell(grid, row, col, grapheme) do
    List.update_at(grid, row, fn r -> Map.put(r, col, grapheme) end)
  end

  defp update_row(grid, row, fun), do: List.update_at(grid, row, fun)

  defp clear_from(row, col), do: row |> Enum.reject(fn {c, _} -> c >= col end) |> Map.new()
  defp clear_to(row, col), do: row |> Enum.reject(fn {c, _} -> c <= col end) |> Map.new()

  defp render_row(row, cols) do
    max_col = row |> Map.keys() |> Enum.max(fn -> -1 end)
    upper = min(max_col, cols - 1)

    if upper < 0 do
      ""
    else
      0..upper
      |> Enum.map(fn c -> Map.get(row, c, " ") end)
      |> Enum.join()
      |> String.trim_trailing()
    end
  end

  defp push_scrollback(s, line) do
    [line | s.scrollback] |> Enum.take(s.max_scrollback)
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp parse_params(""), do: []

  defp parse_params(params) do
    params
    |> String.split(";")
    |> Enum.map(fn
      "" -> nil
      n -> String.to_integer(n)
    end)
  end

  defp arg(nums, idx, default) do
    case Enum.at(nums, idx) do
      nil -> default
      n -> n
    end
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp trim_trailing_blank_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  Render the visible screen, guaranteed to be valid UTF-8.

  `text/1` reproduces whatever bytes the PTY emitted. A process that writes raw
  binary to its terminal therefore makes `text/1` return an invalid-UTF-8
  binary, which raises the moment anything JSON-encodes it on the way to a
  provider or an SSE client. Use this at those boundaries.
  """
  @spec text_utf8(t()) :: String.t()
  def text_utf8(%__MODULE__{} = s), do: s |> text() |> OptimalSystemAgent.Utils.Text.scrub_utf8()
end
