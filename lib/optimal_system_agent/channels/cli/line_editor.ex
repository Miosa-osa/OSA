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
  """

  defstruct [
    buffer: [],
    cursor: 0,
    history: [],
    history_index: -1,
    saved_input: [],
    prompt: "",
    tty: nil  # single fd for /dev/tty, read+write, bypasses Erlang group leader
  ]

  @doc """
  Read a line of input with readline-style editing.

  Returns:
  - `{:ok, string}` — user submitted input
  - `:eof` — Ctrl+D on empty line
  - `:interrupt` — Ctrl+C
  """
  @spec readline(String.t(), list(String.t())) :: {:ok, String.t()} | :eof | :interrupt
  def readline(prompt, history \\ []) do
    case open_tty() do
      {:ok, tty} ->
        result = interactive_readline(prompt, history, tty)
        close_tty(tty)
        result

      {:error, _} ->
        fallback_readline(prompt)
    end
  end

  # --- Interactive mode ---

  defp interactive_readline(prompt, history, tty) do
    saved = save_stty()

    try do
      set_raw_mode()

      state = %__MODULE__{
        prompt: prompt,
        history: history,
        tty: tty
      }

      # Write prompt directly to /dev/tty — bypasses Erlang group leader
      tty_write(tty, prompt)
      input_loop(state)
    after
      # Move to next line while still in raw mode, via direct tty write.
      # This ensures the input line stays visible and cursor is on a new line.
      tty_write(tty, "\n")
      # Restore terminal to cooked mode.
      # Because we never used IO.write (Erlang group leader) during raw mode,
      # user_drv has no buffered content to ghost/replay on mode switch.
      restore_stty(saved)
    end
  end

  defp input_loop(state) do
    case read_key(state.tty) do
      :enter ->
        {:ok, Enum.join(state.buffer)}

      :ctrl_c ->
        :interrupt

      {:ctrl_d, _} when state.buffer == [] ->
        :eof

      {:ctrl_d, _} ->
        # Delete char under cursor (forward delete)
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
        # Kill line before cursor
        {_, after_cursor} = Enum.split(state.buffer, state.cursor)
        state = %{state | buffer: after_cursor, cursor: 0}
        redraw(state)
        input_loop(state)

      :ctrl_k ->
        # Kill line after cursor
        {before_cursor, _} = Enum.split(state.buffer, state.cursor)
        state = %{state | buffer: before_cursor}
        redraw(state)
        input_loop(state)

      :ctrl_w ->
        # Delete word backwards
        state = delete_word_back(state)
        redraw(state)
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

      {:char, ch} ->
        state = insert_char(state, ch)
        redraw(state)
        input_loop(state)

      _ ->
        input_loop(state)
    end
  end

  # --- Buffer operations ---

  defp insert_char(state, ch) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)
    %{state |
      buffer: before ++ [ch] ++ after_cursor,
      cursor: state.cursor + 1,
      history_index: -1
    }
  end

  defp delete_backward(%{cursor: 0} = state), do: state
  defp delete_backward(state) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)
    %{state |
      buffer: Enum.take(before, length(before) - 1) ++ after_cursor,
      cursor: state.cursor - 1
    }
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
    # Drop trailing spaces, then drop non-spaces
    trimmed = before |> Enum.reverse() |> Enum.drop_while(&(&1 == " ")) |> Enum.drop_while(&(&1 != " ")) |> Enum.reverse()
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
    # Return to saved input
    %{state |
      buffer: state.saved_input,
      cursor: length(state.saved_input),
      history_index: -1
    }
  end
  defp history_forward(state) do
    load_history(state, state.history_index - 1)
  end

  defp load_history(state, idx) do
    # Save current input when first entering history
    saved =
      if state.history_index == -1 do
        state.buffer
      else
        state.saved_input
      end

    entry = Enum.at(state.history, idx, "")
    chars = String.graphemes(entry)

    %{state |
      buffer: chars,
      cursor: length(chars),
      history_index: idx,
      saved_input: saved
    }
  end

  # --- Rendering ---

  defp redraw(state) do
    line = Enum.join(state.buffer)
    # Clear line and rewrite — directly to /dev/tty, not through group leader
    tty_write(state.tty, "\r\e[2K#{state.prompt}#{line}")
    # Position cursor
    chars_after = length(state.buffer) - state.cursor
    if chars_after > 0, do: tty_write(state.tty, "\e[#{chars_after}D")
  end

  # --- Terminal I/O ---

  defp open_tty do
    :file.open(~c"/dev/tty", [:read, :write, :raw, :binary])
  end

  defp close_tty(tty), do: :file.close(tty)

  # Write directly to /dev/tty fd, bypassing Erlang's group leader (user_drv).
  # This prevents the ghost duplicate that occurs when user_drv tries to
  # reconcile its internal state after stty mode switches.
  defp tty_write(tty, data) do
    :file.write(tty, data)
  end

  defp save_stty do
    :os.cmd(~c"stty -g 2>/dev/null") |> List.to_string() |> String.trim()
  end

  defp set_raw_mode do
    :os.cmd(~c"stty raw -echo 2>/dev/null")
  end

  defp restore_stty(""), do: :os.cmd(~c"stty sane 2>/dev/null")
  defp restore_stty(saved) do
    :os.cmd(String.to_charlist("stty #{saved} 2>/dev/null"))
  end

  defp read_key(tty) do
    case :file.read(tty, 1) do
      {:ok, <<27>>} -> read_escape(tty)
      {:ok, <<13>>} -> :enter
      {:ok, <<10>>} -> :enter
      {:ok, <<127>>} -> :backspace
      {:ok, <<8>>} -> :backspace
      {:ok, <<3>>} -> :ctrl_c
      {:ok, <<4>>} -> {:ctrl_d, nil}
      {:ok, <<1>>} -> :ctrl_a
      {:ok, <<5>>} -> :ctrl_e
      {:ok, <<11>>} -> :ctrl_k
      {:ok, <<21>>} -> :ctrl_u
      {:ok, <<23>>} -> :ctrl_w
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
  defp read_csi(tty) do
    case :file.read(tty, 1) do
      {:ok, <<"A">>} -> :up
      {:ok, <<"B">>} -> :down
      {:ok, <<"C">>} -> :right
      {:ok, <<"D">>} -> :left
      {:ok, <<"H">>} -> :home
      {:ok, <<"F">>} -> :end_key
      {:ok, <<"3">>} ->
        # Delete key: ESC [ 3 ~
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :delete
          _ -> :unknown
        end
      {:ok, <<"1">>} ->
        # Home: ESC [ 1 ~
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :home
          _ -> :unknown
        end
      {:ok, <<"4">>} ->
        # End: ESC [ 4 ~
        case :file.read(tty, 1) do
          {:ok, <<"~">>} -> :end_key
          _ -> :unknown
        end
      _ -> :unknown
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

  # --- Fallback ---

  defp fallback_readline(prompt) do
    case IO.gets(prompt) do
      :eof -> :eof
      data when is_binary(data) -> {:ok, String.trim_trailing(data, "\n")}
      _ -> :eof
    end
  end
end
