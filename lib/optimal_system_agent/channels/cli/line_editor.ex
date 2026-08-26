defmodule OptimalSystemAgent.Channels.CLI.LineEditor do
  @moduledoc """
  Lightweight readline with arrow key navigation and command history.

  Features:
  - Left/Right arrows — cursor movement within line
  - Up/Down arrows — navigate command history
  - Backspace/Delete — character deletion
  - Home (Ctrl+A) / End (Ctrl+E) — jump to line start/end
  - Ctrl+C — cancel (return :interrupt)
  - Ctrl+D on empty line — EOF (return :eof)
  - Fallback to IO.gets when /dev/tty unavailable

  All terminal I/O during readline goes through a raw /dev/tty fd,
  completely bypassing the Erlang IO system (group_leader → user_drv →
  prim_tty).  This is critical on OTP 26+ where prim_tty does software
  echo and terminal state tracking that conflicts with our own readline.
  """

  alias OptimalSystemAgent.CLI.Width

  defstruct buffer: [],
            cursor: 0,
            history: [],
            history_index: -1,
            saved_input: [],
            prompt: "",
            # fd for /dev/tty — used for BOTH raw byte reads AND writes
            tty: nil,
            terminal_cols: 80,
            # Grapheme index the current selection started at, or nil when
            # nothing is selected. The selected range is always the span
            # between this and `cursor`, in either direction, so a drag
            # leftwards selects exactly what a drag rightwards would.
            selection_anchor: nil

  @doc """
  Read a line of input with readline-style editing.

  Returns:
  - `{:ok, string}` — user submitted input
  - `:eof` — Ctrl+D on empty line
  - `:interrupt` — Ctrl+C
  """
  @spec readline(String.t(), list(String.t())) :: {:ok, String.t()} | :eof | :interrupt
  def readline(prompt, history \\ []) do
    # On Windows there is no /dev/tty; go straight to the safe fallback that
    # guards against a lost console handle (backgrounded process, piped output).
    if windows?() do
      fallback_readline(prompt)
    else
      case open_tty() do
        {:ok, tty} ->
          result = interactive_readline(prompt, history, tty)
          close_tty(tty)
          result

        {:error, _} ->
          fallback_readline(prompt)
      end
    end
  end

  # Returns true when the Erlang VM is running on Windows (win32 kernel).
  defp windows?, do: match?({:win32, _}, :os.type())

  # --- Interactive mode ---

  defp interactive_readline(prompt, history, tty) do
    saved = save_stty()

    case set_raw_mode() do
      :ok ->
        try do
          state = %__MODULE__{
            prompt: prompt,
            history: history,
            tty: tty,
            terminal_cols: terminal_columns()
          }

          Process.put(:rendered_cursor_row, 0)
          # SGR mouse reporting (1006) with button+drag events (1002). Without
          # these the terminal never reports clicks at all, which is why the
          # editor was keyboard-only. Disabled again in the `after` block so a
          # crash cannot leave the terminal emitting mouse escapes into the
          # user's shell.
          tty_write(tty, "\e[?1002h\e[?1006h")
          tty_write(tty, prompt)
          result = input_loop(state)
          # Newline while still in raw mode (OPOST off → literal \r\n).
          # Must happen BEFORE restore_stty to avoid ONLCR doubling \r.
          tty_write(tty, "\r\n")
          result
        after
          tty_write(tty, "\e[?1006l\e[?1002l")
          Process.delete(:rendered_cursor_row)
          restore_stty(saved)
        end

      :error ->
        # stty failed — fall back to IO.gets to avoid double-echo.
        # Caller (readline/2) handles close_tty.
        fallback_readline(prompt)
    end
  end

  defp input_loop(state) do
    case read_key(state.tty) do
      :enter ->
        text = Enum.join(state.buffer)
        # Move cursor to the last rendered line so the caller's \r\n lands below
        # all content rather than overwriting a middle line.
        layout =
          visual_layout(text, Width.visible(state.prompt), state.terminal_cols, state.cursor)

        lines_below = layout.rendered_rows - 1 - layout.cursor_row

        if lines_below > 0 do
          tty_write(state.tty, "\e[#{lines_below}B")
        end

        {:ok, text}

      :ctrl_c ->
        :interrupt

      {:ctrl_d, _} when state.buffer == [] ->
        :eof

      {:ctrl_d, _} ->
        state = delete_forward(state)
        redraw(state)
        input_loop(state)

      :ctrl_a ->
        state = %{state | cursor: 0}
        redraw(state)
        input_loop(state)

      :ctrl_e ->
        state = %{state | cursor: length(state.buffer)}
        redraw(state)
        input_loop(state)

      :ctrl_u ->
        {_, after_cursor} = Enum.split(state.buffer, state.cursor)
        state = %{state | buffer: after_cursor, cursor: 0}
        redraw(state)
        input_loop(state)

      :ctrl_k ->
        {before_cursor, _} = Enum.split(state.buffer, state.cursor)
        state = %{state | buffer: before_cursor}
        redraw(state)
        input_loop(state)

      :ctrl_w ->
        state = delete_word_back(state)
        redraw(state)
        input_loop(state)

      :ctrl_t ->
        toggle_task_display(state.tty)
        input_loop(state)

      :ctrl_r ->
        # Reverse history search
        state = reverse_search_mode(state)
        redraw(state)
        input_loop(state)

      # Left button pressed (0) — move the cursor there and start a selection
      # anchored at the click. Any previous selection is dropped: a fresh click
      # is how a user cancels one.
      {:mouse, 0, col, row, true} ->
        index = click_index(state, row, col)
        state = %{state | cursor: index, selection_anchor: index}
        redraw(state)
        input_loop(state)

      # Left button dragged (32) — extend the selection to here, keeping the
      # anchor where the press landed.
      {:mouse, 32, col, row, true} ->
        state = %{state | cursor: click_index(state, row, col)}
        redraw(state)
        input_loop(state)

      # Release and every other button: no cursor movement. A right-click or
      # scroll must not silently relocate the caret mid-edit.
      {:mouse, _button, _col, _row, _press} ->
        input_loop(state)

      :backspace ->
        state = delete_backward(state)
        redraw(state)
        input_loop(state)

      :left when state.cursor > 0 ->
        state = %{state | cursor: state.cursor - 1}
        redraw(state)
        input_loop(state)

      :right when state.cursor < length(state.buffer) ->
        state = %{state | cursor: state.cursor + 1}
        redraw(state)
        input_loop(state)

      :up ->
        state = history_back(state)
        redraw(state)
        input_loop(state)

      :down ->
        state = history_forward(state)
        redraw(state)
        input_loop(state)

      :home ->
        state = %{state | cursor: 0}
        redraw(state)
        input_loop(state)

      :end_key ->
        state = %{state | cursor: length(state.buffer)}
        redraw(state)
        input_loop(state)

      :delete ->
        state = delete_forward(state)
        redraw(state)
        input_loop(state)

      :ctrl_j ->
        # Insert a literal newline for multi-line editing
        {before, after_cursor} = Enum.split(state.buffer, state.cursor)

        state = %{
          state
          | buffer: before ++ ["\n"] ++ after_cursor,
            cursor: state.cursor + 1,
            history_index: -1
        }

        redraw(state)
        input_loop(state)

      :tab ->
        state = handle_tab_completion(state)
        input_loop(state)

      {:char, ch} ->
        state = insert_char(state, ch)
        redraw(state)
        input_loop(state)

      _ ->
        input_loop(state)
    end
  end

  # --- Buffer operations ---

  # Typing over a selection REPLACES it, which is what makes "select the wrong
  # word, type the right one" work. Without this the new character is inserted
  # and the selection silently survives, so the next keystroke deletes text the
  # user thought they had already replaced.
  defp insert_char(%{selection_anchor: anchor, cursor: cursor} = state, ch)
       when not is_nil(anchor) and anchor != cursor do
    {buffer, cursor} = delete_selection(state.buffer, anchor, cursor)

    state
    |> Map.merge(%{buffer: buffer, cursor: cursor, selection_anchor: nil})
    |> insert_char(ch)
  end

  defp insert_char(state, ch) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)

    %{
      state
      | buffer: before ++ [ch] ++ after_cursor,
        cursor: state.cursor + 1,
        history_index: -1,
        selection_anchor: nil
    }
  end

  # A live selection is deleted as a UNIT, so Backspace on selected text removes
  # the selection rather than one character from its edge. This clause has to
  # come first, including at cursor 0 - a selection anchored to the right of
  # position 0 is still deletable there.
  defp delete_backward(%{selection_anchor: anchor, cursor: cursor} = state)
       when not is_nil(anchor) and anchor != cursor do
    {buffer, cursor} = delete_selection(state.buffer, anchor, cursor)
    %{state | buffer: buffer, cursor: cursor, selection_anchor: nil}
  end

  defp delete_backward(%{cursor: 0} = state), do: %{state | selection_anchor: nil}

  defp delete_backward(state) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)

    %{
      state
      | buffer: Enum.take(before, length(before) - 1) ++ after_cursor,
        cursor: state.cursor - 1
    }
  end

  defp delete_forward(%{selection_anchor: anchor, cursor: cursor} = state)
       when not is_nil(anchor) and anchor != cursor do
    {buffer, cursor} = delete_selection(state.buffer, anchor, cursor)
    %{state | buffer: buffer, cursor: cursor, selection_anchor: nil}
  end

  defp delete_forward(state) do
    if state.cursor >= length(state.buffer) do
      state
    else
      {before, [_ | rest]} = Enum.split(state.buffer, state.cursor)
      %{state | buffer: before ++ rest}
    end
  end

  defp delete_word_back(%{cursor: 0} = state), do: state

  defp delete_word_back(state) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)

    trimmed =
      before
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == " "))
      |> Enum.drop_while(&(&1 != " "))
      |> Enum.reverse()

    new_cursor = length(trimmed)
    %{state | buffer: trimmed ++ after_cursor, cursor: new_cursor}
  end

  # --- History ---

  defp history_back(state) do
    max_idx = length(state.history) - 1
    if max_idx < 0, do: state, else: do_history_back(state, max_idx)
  end

  defp do_history_back(state, max_idx) do
    next_idx = min(state.history_index + 1, max_idx)
    if next_idx == state.history_index, do: state, else: load_history(state, next_idx)
  end

  defp history_forward(%{history_index: -1} = state), do: state

  defp history_forward(%{history_index: 0} = state) do
    %{state | buffer: state.saved_input, cursor: length(state.saved_input), history_index: -1}
  end

  defp history_forward(state) do
    load_history(state, state.history_index - 1)
  end

  defp load_history(state, idx) do
    saved =
      if state.history_index == -1 do
        state.buffer
      else
        state.saved_input
      end

    entry = Enum.at(state.history, idx, "")
    chars = String.graphemes(entry)

    %{state | buffer: chars, cursor: length(chars), history_index: idx, saved_input: saved}
  end

  # --- Rendering ---
  # All writes go through tty_write (direct /dev/tty fd), NOT IO.write.
  # This bypasses Erlang's group_leader → user_drv → prim_tty pipeline,
  # which in OTP 26+ does software echo and line-state tracking that
  # would duplicate our own rendering.

  defp redraw(state) do
    line = Enum.join(state.buffer)
    # Selection highlight is applied per line; layout still measures the PLAIN
    # text, because the escape codes occupy no columns.
    lines = decorate_lines(line, state.selection_anchor, state.cursor)
    cols = terminal_columns(state.terminal_cols)
    layout = visual_layout(line, Width.visible(state.prompt), cols, state.cursor)

    # Track the previous visual cursor row since redraw is side-effect-only and
    # does not return an updated state.
    prev_cursor_row = Process.get(:rendered_cursor_row, 0)

    # Move up to the first rendered line so we can overwrite everything.
    if prev_cursor_row > 0 do
      tty_write(state.tty, "\e[#{prev_cursor_row}A")
    end

    # Clear from here to end of screen.
    tty_write(state.tty, "\r\e[J")

    # Render all lines.
    [first | rest] = lines
    tty_write(state.tty, "#{state.prompt}#{first}")

    for continuation <- rest do
      tty_write(state.tty, "\r\n  #{continuation}")
    end

    # Position cursor on the correct line and column.
    lines_from_end = layout.rendered_rows - 1 - layout.cursor_row

    if lines_from_end > 0 do
      tty_write(state.tty, "\e[#{lines_from_end}A")
    end

    tty_write(state.tty, "\r")

    if layout.cursor_col > 0 do
      tty_write(state.tty, "\e[#{layout.cursor_col}C")
    end

    Process.put(:rendered_cursor_row, layout.cursor_row)
  end

  @doc false
  @spec visual_layout(String.t(), non_neg_integer(), pos_integer(), non_neg_integer()) :: map()
  def visual_layout(text, prompt_width, terminal_cols, cursor)
      when is_binary(text) and is_integer(prompt_width) and is_integer(terminal_cols) and
             terminal_cols > 0 and is_integer(cursor) do
    logical_lines = String.split(text, "\n")
    before = text |> String.graphemes() |> Enum.take(max(cursor, 0)) |> Enum.join()
    before_lines = String.split(before, "\n")
    cursor_logical_line = length(before_lines) - 1
    cursor_text = List.last(before_lines) || ""

    rows_per_line =
      logical_lines
      |> Enum.with_index()
      |> Enum.map(fn {logical, index} ->
        prefix = if index == 0, do: prompt_width, else: 2
        visual_rows(prefix + Width.visible(logical), terminal_cols)
      end)

    rows_before = rows_per_line |> Enum.take(cursor_logical_line) |> Enum.sum()
    cursor_prefix = if cursor_logical_line == 0, do: prompt_width, else: 2
    cursor_offset = cursor_prefix + Width.visible(cursor_text)
    {cursor_wrap_row, cursor_col} = visual_cursor(cursor_offset, terminal_cols)

    %{
      rendered_rows: Enum.sum(rows_per_line),
      cursor_row: rows_before + cursor_wrap_row,
      cursor_col: cursor_col
    }
  end

  @doc """
  The grapheme index a click at `{row, col}` refers to — the inverse of
  `visual_layout/4`.

  Defined BY `visual_layout/4` rather than by re-deriving the arithmetic: it
  walks candidate cursor positions and picks the one the renderer would draw
  closest to the click. That is O(n) layouts per click, which is nothing at
  human click rates, and it buys the property that matters — the mapping cannot
  disagree with the rendering, because it IS the rendering.

  Re-deriving it independently is how you get a prompt-prefix counted twice on
  the first row and every click landing one column off.

  `row` and `col` are 0-based and relative to the first row of the prompt.
  """
  @spec index_at(String.t(), non_neg_integer(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def index_at(text, prompt_width, terminal_cols, row, col)
      when is_binary(text) and is_integer(prompt_width) and is_integer(terminal_cols) and
             terminal_cols > 0 do
    last = text |> String.graphemes() |> length()

    0..last
    |> Enum.min_by(fn index ->
      layout = visual_layout(text, prompt_width, terminal_cols, index)
      # Row dominates: a click on row 2 must never resolve to row 1, however
      # close the columns happen to be.
      abs(layout.cursor_row - row) * (terminal_cols + 1) + abs(layout.cursor_col - col)
    end)
  end

  @doc """
  Parse the payload of an SGR mouse report (`ESC [ <` already consumed).

  The wire form is `button ; col ; row (M|m)` — `M` press, `m` release — with
  1-based col/row. Returns 0-based coordinates so they compose with
  `index_at/5`, or `:unknown` for anything unrecognised, so a malformed report
  is discarded rather than moving the cursor somewhere arbitrary.
  """
  @spec parse_sgr_mouse(String.t()) ::
          {:mouse, non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean()} | :unknown
  def parse_sgr_mouse(payload) when is_binary(payload) do
    with [rest, final] <- split_mouse_final(payload),
         [b, c, r] <- String.split(rest, ";"),
         {button, ""} <- Integer.parse(b),
         {mouse_col, ""} <- Integer.parse(c),
         {mouse_row, ""} <- Integer.parse(r),
         true <- button >= 0 and mouse_col >= 1 and mouse_row >= 1 do
      {:mouse, button, mouse_col - 1, mouse_row - 1, final == "M"}
    else
      _ -> :unknown
    end
  end

  def parse_sgr_mouse(_), do: :unknown

  defp split_mouse_final(payload) do
    case String.last(payload) do
      f when f in ["M", "m"] -> [String.slice(payload, 0..-2//1), f]
      _ -> :no_final
    end
  end

  @doc """
  The logical lines of `text`, each with its slice of the selection wrapped in
  reverse video.

  Applied PER LINE rather than once around the whole span. The renderer writes a
  `\\r\\n` and a continuation prefix between lines, so a single reverse-video
  region opened before a newline would keep the attribute switched on across the
  break and paint the prefix — and, on some terminals, the rest of the row — as
  selected. Re-opening per line keeps the highlight on exactly the characters
  that are selected.

  Returns plain lines when nothing is selected, so the renderer can call this
  unconditionally.
  """
  @spec decorate_lines(String.t(), non_neg_integer() | nil, non_neg_integer()) :: [String.t()]
  def decorate_lines(text, anchor, cursor) do
    case selection_range(anchor, cursor) do
      nil ->
        String.split(text, "\n")

      {start, len} ->
        sel_end = start + len

        text
        |> String.split("\n")
        |> Enum.reduce({[], 0}, fn line, {acc, offset} ->
          length_in_graphemes = line |> String.graphemes() |> length()
          line_end = offset + length_in_graphemes

          decorated = decorate_line(line, max(start - offset, 0), min(sel_end, line_end) - offset)

          # +1 for the newline that was split out, so offsets stay aligned with
          # grapheme indices in the original text.
          {[decorated | acc], line_end + 1}
        end)
        |> elem(0)
        |> Enum.reverse()
    end
  end

  # `from`/`to` are grapheme offsets within THIS line; an empty or inverted span
  # means the selection does not touch it.
  defp decorate_line(line, from, to) when to <= from, do: line

  defp decorate_line(line, from, to) do
    graphemes = String.graphemes(line)
    {before, rest} = Enum.split(graphemes, from)
    {selected, tail} = Enum.split(rest, to - from)

    case Enum.join(selected) do
      "" -> line
      sel -> Enum.join(before) <> "\e[7m" <> sel <> "\e[27m" <> Enum.join(tail)
    end
  end

  @doc """
  The selected span as `{start, length}`, or `nil` when nothing is selected.

  Normalised so a drag leftwards selects exactly what the same drag rightwards
  would: the anchor may sit on either side of the cursor.
  """
  @spec selection_range(non_neg_integer() | nil, non_neg_integer()) ::
          {non_neg_integer(), pos_integer()} | nil
  def selection_range(nil, _cursor), do: nil

  def selection_range(anchor, cursor) when anchor == cursor, do: nil

  def selection_range(anchor, cursor) do
    start = min(anchor, cursor)
    {start, abs(cursor - anchor)}
  end

  @doc """
  Remove the selected span from `buffer`, returning `{buffer, cursor}`.

  The cursor lands at the START of the removed span — where the text used to
  begin — which is what every other editor does and what makes "select, then
  type the replacement" work.

  Returns the buffer untouched when there is no selection, so callers can route
  every delete through this without checking first.
  """
  @spec delete_selection([String.t()], non_neg_integer() | nil, non_neg_integer()) ::
          {[String.t()], non_neg_integer()}
  def delete_selection(buffer, anchor, cursor) do
    case selection_range(anchor, cursor) do
      nil ->
        {buffer, cursor}

      {start, len} ->
        # Split at the START and drop `len` from the tail half. Splitting at the
        # wrong half here deletes the text on the other side of the selection -
        # which looks like the editor eating the line you did not touch.
        {before, rest} = Enum.split(buffer, start)
        {before ++ Enum.drop(rest, len), start}
    end
  end

  @doc """
  Split `text` into `{before, selected, after}` for rendering.

  Used to wrap the selected span in reverse video without the renderer needing
  to know how selections are represented.
  """
  @spec selection_split(String.t(), non_neg_integer() | nil, non_neg_integer()) ::
          {String.t(), String.t(), String.t()}
  def selection_split(text, anchor, cursor) do
    case selection_range(anchor, cursor) do
      nil ->
        {text, "", ""}

      {start, len} ->
        graphemes = String.graphemes(text)
        {before, rest} = Enum.split(graphemes, start)
        {selected, rest} = Enum.split(rest, len)
        {Enum.join(before), Enum.join(selected), Enum.join(rest)}
    end
  end

  # Terminal (row, col) → grapheme index, against the text as currently drawn.
  defp click_index(state, row, col) do
    index_at(
      Enum.join(state.buffer),
      Width.visible(state.prompt),
      max(state.terminal_cols, 1),
      row,
      col
    )
  end

  defp visual_rows(width, cols), do: max(div(max(width, 1) - 1, cols) + 1, 1)

  defp visual_cursor(0, _cols), do: {0, 0}

  defp visual_cursor(offset, cols) do
    case rem(offset, cols) do
      0 -> {div(offset, cols) - 1, cols}
      col -> {div(offset, cols), col}
    end
  end

  # Width of the real terminal, in columns.
  #
  # `:io.columns/0` is asked first and almost always FAILS here: this readline
  # reads a raw `/dev/tty` fd directly, bypassing `prim_tty`, and the Erlang IO
  # system then answers `{:error, :enotsup}`. The old code fell straight to a
  # hardcoded 80, so on any wider terminal the wrap arithmetic used the wrong
  # column count and long input wrapped early with its tail invisible - the
  # defect reported in #121.
  #
  # `stty size` is asked next, against the same `/dev/tty` the editor already
  # opens for raw-mode control, so it reports the width of the terminal actually
  # in use rather than whatever the BEAM thinks it has.
  defp terminal_columns(fallback \\ 80) do
    case :io.columns() do
      {:ok, cols} when is_integer(cols) and cols > 0 -> cols
      _ -> stty_columns(fallback)
    end
  rescue
    _ -> stty_columns(fallback)
  end

  defp stty_columns(fallback) do
    case run_stty(["size"]) do
      {:ok, output} -> parse_stty_size(output, fallback)
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  @doc """
  Columns from `stty size` output, which prints `"<rows> <cols>"`.

  Split out as a pure function so the parsing IS testable. The shell-out itself
  needs a live terminal fd and cannot run under `mix test`, but that is no
  reason for the string handling - the part that actually goes wrong - to be
  untested too.
  """
  @spec parse_stty_size(String.t(), pos_integer()) :: pos_integer()
  def parse_stty_size(output, fallback) when is_binary(output) do
    with [_rows, cols] <- output |> String.trim() |> String.split(~r/\s+/, parts: 2),
         {n, _} <- Integer.parse(cols),
         true <- n > 0 do
      n
    else
      _ -> fallback
    end
  end

  def parse_stty_size(_, fallback), do: fallback

  # --- Tab Completion ---

  @known_commands ~w(
    help model clear compact context cost exit quit
    sessions resume status agents tools soul thinking
    strategy swarm plan permission orchestrate
    login logout new doctor export version tasks
    skills coordinator memory setup channels
    effort fast goal
  )

  defp handle_tab_completion(state) do
    text = Enum.join(state.buffer)

    if String.starts_with?(text, "/") do
      partial = String.slice(text, 1..-1//1)
      matches = Enum.filter(@known_commands, &String.starts_with?(&1, partial))

      case matches do
        [single] ->
          completed = "/" <> single <> " "
          chars = String.graphemes(completed)
          state = %{state | buffer: chars, cursor: length(chars)}
          redraw(state)
          state

        multiple when length(multiple) > 0 ->
          tty_write(state.tty, "\r\n")

          for cmd <- multiple do
            tty_write(state.tty, "  /#{cmd}\r\n")
          end

          prefix = common_prefix(multiple)

          if String.length(prefix) > String.length(partial) do
            completed = "/" <> prefix
            chars = String.graphemes(completed)
            state = %{state | buffer: chars, cursor: length(chars)}
            redraw(state)
            state
          else
            redraw(state)
            state
          end

        [] ->
          state
      end
    else
      state
    end
  end

  defp common_prefix([]), do: ""
  defp common_prefix([single]), do: single

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn str, acc ->
      Enum.zip(String.graphemes(acc), String.graphemes(str))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(fn {a, _} -> a end)
      |> Enum.join()
    end)
  end

  # --- Terminal I/O ---

  # Open /dev/tty for both reading AND writing.
  # We bypass the Erlang IO system entirely during readline.
  defp open_tty do
    :file.open(~c"/dev/tty", [:read, :write, :raw, :binary])
  end

  defp close_tty(tty), do: :file.close(tty)

  # Write directly to /dev/tty fd — bypasses prim_tty completely.
  defp tty_write(tty, data) do
    :file.write(tty, data)
  end

  # Terminal attribute control via Port.open + spawn_executable.
  #
  # Why not :os.cmd?  :os.cmd redirects subprocess stdin to a pipe,
  # so `stty` can't find the terminal even with `< /dev/tty` — the
  # redirect happens inside a subshell whose fd setup is unreliable.
  #
  # Port.open({:spawn_executable, path}, args: [...]) runs the binary
  # directly (no shell).  The -f flag (macOS) / -F flag (Linux) tells
  # stty to operate on /dev/tty explicitly, sidestepping stdin entirely.

  defp save_stty do
    case run_stty(["-g"]) do
      {:ok, settings} -> settings
      _ -> ""
    end
  end

  defp set_raw_mode do
    case run_stty(["raw", "-echo"]) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp restore_stty(""), do: run_stty(["sane"])

  defp restore_stty(saved) do
    run_stty([saved])
  end

  defp run_stty(args) do
    flag = stty_device_flag()
    exe = stty_executable()

    port =
      Port.open(
        {:spawn_executable, exe},
        [:binary, :exit_status, :stderr_to_stdout, args: [flag, "/dev/tty" | args]]
      )

    collect_port_output(port, "")
  rescue
    _ -> {:error, :port_failed}
  end

  # ERTS guarantees exit_status is always the last message for a port —
  # no {:data, _} can arrive after {:exit_status, _} per open_port/2 docs.
  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim(acc)}

      {^port, {:exit_status, _code}} ->
        {:error, String.trim(acc)}
    after
      2_000 ->
        Port.close(port)
        flush_port(port)
        {:error, :timeout}
    end
  end

  # Drain stale port messages from the mailbox after timeout/close.
  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp stty_executable do
    case :os.find_executable(~c"stty") do
      false -> ~c"/bin/stty"
      path -> path
    end
  end

  defp stty_device_flag do
    case :os.type() do
      {:unix, :darwin} -> "-f"
      {:unix, _} -> "-F"
      _ -> "-f"
    end
  end

  defp read_key(tty) do
    case :file.read(tty, 1) do
      {:ok, <<27>>} -> read_escape(tty)
      {:ok, <<13>>} -> :enter
      {:ok, <<10>>} -> :ctrl_j
      {:ok, <<9>>} -> :tab
      {:ok, <<127>>} -> :backspace
      {:ok, <<8>>} -> :backspace
      {:ok, <<3>>} -> :ctrl_c
      {:ok, <<4>>} -> {:ctrl_d, nil}
      {:ok, <<1>>} -> :ctrl_a
      {:ok, <<5>>} -> :ctrl_e
      {:ok, <<11>>} -> :ctrl_k
      {:ok, <<21>>} -> :ctrl_u
      {:ok, <<23>>} -> :ctrl_w
      {:ok, <<18>>} -> :ctrl_r
      {:ok, <<20>>} -> :ctrl_t
      {:ok, <<ch>>} when ch >= 32 -> {:char, <<ch::utf8>>}
      {:ok, bytes} -> maybe_utf8(tty, bytes)
      _ -> :unknown
    end
  end

  # Handle multi-byte UTF-8 sequences
  defp maybe_utf8(tty, <<lead>>) when lead >= 0xC0 and lead < 0xE0 do
    case :file.read(tty, 1) do
      {:ok, cont} -> {:char, <<lead>> <> cont}
      _ -> :unknown
    end
  end

  defp maybe_utf8(tty, <<lead>>) when lead >= 0xE0 and lead < 0xF0 do
    case :file.read(tty, 2) do
      {:ok, cont} -> {:char, <<lead>> <> cont}
      _ -> :unknown
    end
  end

  defp maybe_utf8(tty, <<lead>>) when lead >= 0xF0 do
    case :file.read(tty, 3) do
      {:ok, cont} -> {:char, <<lead>> <> cont}
      _ -> :unknown
    end
  end

  defp maybe_utf8(_, _), do: :unknown

  defp read_escape(tty) do
    case :file.read(tty, 1) do
      {:ok, <<"[">>} -> read_csi(tty)
      {:ok, <<"O">>} -> read_ss3(tty)
      _ -> :escape
    end
  end

  # CSI sequences: ESC [ ...
  # Read an SGR mouse report byte by byte until its final `M`/`m`.
  #
  # Bounded at 32 bytes: a well-formed report is ~12, and an unbounded read on a
  # malformed sequence would block the editor forever waiting for a terminator
  # that never arrives.
  defp read_sgr_mouse(_tty, acc) when byte_size(acc) > 32, do: :unknown

  defp read_sgr_mouse(tty, acc) do
    case :file.read(tty, 1) do
      {:ok, <<c::binary-size(1)>>} when c in ["M", "m"] ->
        parse_sgr_mouse(acc <> c)

      {:ok, <<c::binary-size(1)>>} ->
        read_sgr_mouse(tty, acc <> c)

      _ ->
        :unknown
    end
  end

  defp read_csi(tty) do
    case :file.read(tty, 1) do
      # SGR mouse: ESC [ < button ; col ; row (M|m)
      {:ok, <<"<">>} ->
        read_sgr_mouse(tty, "")

      {:ok, <<"A">>} ->
        :up

      {:ok, <<"B">>} ->
        :down

      {:ok, <<"C">>} ->
        :right

      {:ok, <<"D">>} ->
        :left

      {:ok, <<"H">>} ->
        :home

      {:ok, <<"F">>} ->
        :end_key

      {:ok, <<"3">>} ->
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :delete
          _ -> :unknown
        end

      {:ok, <<"1">>} ->
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :home
          _ -> :unknown
        end

      {:ok, <<"4">>} ->
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :end_key
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  # SS3 sequences: ESC O ...
  defp read_ss3(tty) do
    case :file.read(tty, 1) do
      {:ok, <<"H">>} -> :home
      {:ok, <<"F">>} -> :end_key
      _ -> :unknown
    end
  end

  # --- Task Display Toggle ---

  # Uses tty_write (raw /dev/tty fd) — NOT IO.write — because this
  # runs inside input_loop during raw mode.
  defp toggle_task_display(tty) do
    try do
      sessions =
        try do
          :ets.match(:osa_settings, {{:"$1", :task_display_visible}, :"$2"})
        rescue
          _ -> []
        end

      case sessions do
        [[sid, current] | _] ->
          new_val = !current
          :ets.insert(:osa_settings, {{sid, :task_display_visible}, new_val})
          label = if new_val, do: "  task panel: on", else: "  task panel: off"
          tty_write(tty, "\r\e[2K\e[1A\e[2K#{label}\r\n")

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  # --- Reverse Search ---

  defp reverse_search_mode(state) do
    # Simple reverse search: prompt for search term, find match in history
    tty = state.tty
    tty_write(tty, "\r\e[2K\e[2m(reverse-i-search)`': \e[0m")

    search_term = read_search_input(tty, "")

    if search_term == "" do
      state
    else
      # Find the first history entry containing the search term
      match =
        Enum.find(state.history, fn entry ->
          String.contains?(String.downcase(entry), String.downcase(search_term))
        end)

      case match do
        nil ->
          tty_write(tty, "\r\e[2K\e[33mno match: #{search_term}\e[0m")
          Process.sleep(800)
          state

        found ->
          # Set the buffer to the found entry
          chars = String.graphemes(found)
          %{state | buffer: chars, cursor: length(chars)}
      end
    end
  end

  defp read_search_input(tty, acc) do
    case :file.read(tty, 1) do
      # Enter — accept
      {:ok, <<13>>} ->
        acc

      # Ctrl+C — cancel
      {:ok, <<3>>} ->
        ""

      # Escape — accept
      {:ok, <<27>>} ->
        acc

      # Backspace
      {:ok, <<127>>} ->
        new_acc = String.slice(acc, 0, max(String.length(acc) - 1, 0))
        tty_write(tty, "\r\e[2K\e[2m(reverse-i-search)`#{new_acc}': \e[0m")
        read_search_input(tty, new_acc)

      {:ok, <<ch>>} when ch >= 32 ->
        new_acc = acc <> <<ch>>
        tty_write(tty, "\r\e[2K\e[2m(reverse-i-search)`#{new_acc}': \e[0m")
        read_search_input(tty, new_acc)

      _ ->
        acc
    end
  end

  # --- Fallback ---

  defp fallback_readline(prompt) do
    case IO.gets(prompt) do
      :eof -> :eof
      {:error, reason} when reason in [:enotsup, :eio, :closed] -> :eof
      data when is_binary(data) -> {:ok, String.trim_trailing(data, "\n")}
      _ -> :eof
    end
  rescue
    # Erlang raises ErlangError wrapping :enotsup / :eio when the Windows
    # console HANDLE has been lost (process backgrounded / terminal closed).
    ErlangError -> :eof
  end
end
