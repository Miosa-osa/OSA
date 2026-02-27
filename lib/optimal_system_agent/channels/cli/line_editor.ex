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

  defstruct buffer: [],
            cursor: 0,
            history: [],
            history_index: -1,
            saved_input: [],
            prompt: "",
            # fd for /dev/tty — used for BOTH raw byte reads AND writes
            tty: nil

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

    case set_raw_mode() do
      :ok ->
        try do
          state = %__MODULE__{
            prompt: prompt,
            history: history,
            tty: tty
          }

          tty_write(tty, prompt)
          result = input_loop(state)
          # Newline while still in raw mode (OPOST off → literal \r\n).
          # Must happen BEFORE restore_stty to avoid ONLCR doubling \r.
          tty_write(tty, "\r\n")
          result
        after
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
        {:ok, Enum.join(state.buffer)}

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
    %{state | buffer: before ++ [ch] ++ after_cursor, cursor: state.cursor + 1, history_index: -1}
  end

  defp delete_backward(%{cursor: 0} = state), do: state

  defp delete_backward(state) do
    {before, after_cursor} = Enum.split(state.buffer, state.cursor)

    %{
      state
      | buffer: Enum.take(before, length(before) - 1) ++ after_cursor,
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
    tty_write(state.tty, "\r\e[2K#{state.prompt}#{line}")

    chars_after = length(state.buffer) - state.cursor
    if chars_after > 0, do: tty_write(state.tty, "\e[#{chars_after}D")
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
  defp read_csi(tty) do
    case :file.read(tty, 1) do
      {:ok, <<"A">>} -> :up
      {:ok, <<"B">>} -> :down
      {:ok, <<"C">>} -> :right
      {:ok, <<"D">>} -> :left
      {:ok, <<"H">>} -> :home
      {:ok, <<"F">>} -> :end_key

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

  # --- Fallback ---

  defp fallback_readline(prompt) do
    case IO.gets(prompt) do
      :eof -> :eof
      data when is_binary(data) -> {:ok, String.trim_trailing(data, "\n")}
      _ -> :eof
    end
  end
end
