defmodule OptimalSystemAgent.CLI.Prompt do
  @moduledoc """
  Interactive terminal prompts with arrow-key navigation.

  Provides @clack/prompts-style inline terminal UI:
  - Arrow-key single select (●/○)
  - Space-toggle multiselect (◼/◻)
  - Text input with masking
  - Yes/No confirmation
  - Bordered note boxes
  - Spinners
  - Intro/outro flow markers

  Uses Erlang `:io` in raw mode for real-time key reading.
  ANSI escape codes for cursor movement and redrawing.
  """

  @bar "│"
  @diamond "\e[36m\e[1m◆\e[0m"
  @diamond_dim "\e[2m◇\e[0m"
  @check "\e[32m✓\e[0m"
  @cross "\e[31m✗\e[0m"

  # ── Flow Markers ──────────────────────────────────────────────

  @doc "Print flow start marker."
  def intro(title) do
    IO.puts("\e[36m\e[1m┌  #{title}\e[0m")
    IO.puts("\e[2m#{@bar}\e[0m")
  end

  @doc "Print flow end marker."
  def outro(message) do
    IO.puts("")
    IO.puts("\e[32m\e[1m└  #{message}\e[0m")
    IO.puts("")
  end

  @doc "Print a completed step (dimmed)."
  def completed(label, value) do
    IO.puts("\e[2m◇  #{label}\e[0m")
    IO.puts("\e[32m#{@bar}  ✓ #{value}\e[0m")
    IO.puts("\e[2m#{@bar}\e[0m")
  end

  # ── Bordered Note ─────────────────────────────────────────────

  @doc "Print a bordered information box."
  def note(message, title) do
    lines = String.split(message, "\n")

    max_len =
      Enum.reduce(lines, String.length(title) + 4, fn line, acc ->
        max(acc, String.length(line) + 4)
      end)

    border_top = String.duplicate("─", max_len)
    border_bot = String.duplicate("─", max_len)

    IO.puts("\e[2m◇  #{title} #{border_top}╮\e[0m")

    Enum.each(lines, fn line ->
      padding = String.duplicate(" ", max(max_len - String.length(line) - 2, 0))
      IO.puts("\e[2m#{@bar}  #{line}#{padding}  #{@bar}\e[0m")
    end)

    IO.puts("\e[2m├#{border_bot}──╯\e[0m")
    IO.puts("\e[2m#{@bar}\e[0m")
  end

  # ── Single Select (arrow keys) ────────────────────────────────

  @doc """
  Arrow-key single select. Returns the selected option's value.

  Options: list of `%{value: term, label: String.t, hint: String.t}`
  """
  def select(message, options, opts \\ []) do
    initial = Keyword.get(opts, :initial, 0)

    IO.puts("#{@diamond}  \e[1m#{message}\e[0m")

    # Enter raw mode
    prev_opts = set_raw_mode()

    try do
      result = select_loop(options, initial)

      # Clear the options and show completed state
      clear_lines(length(options))
      # blank line after clearing
      IO.puts("")

      case result do
        {:ok, idx} ->
          selected = Enum.at(options, idx)
          # Show as completed
          # move up to overwrite blank
          IO.write("\e[A")
          # clear line
          IO.write("\e[2K")
          completed(message, selected.label)
          selected.value

        :cancel ->
          IO.puts("\e[2m#{@bar}  Cancelled\e[0m")
          nil
      end
    after
      restore_mode(prev_opts)
    end
  end

  defp select_loop(options, selected) do
    draw_select_options(options, selected)

    case read_key() do
      :up ->
        new = if selected > 0, do: selected - 1, else: length(options) - 1
        clear_lines(length(options))
        select_loop(options, new)

      :down ->
        new = if selected < length(options) - 1, do: selected + 1, else: 0
        clear_lines(length(options))
        select_loop(options, new)

      :enter ->
        {:ok, selected}

      :escape ->
        :cancel

      _ ->
        select_loop(options, selected)
    end
  end

  defp draw_select_options(options, selected) do
    Enum.with_index(options)
    |> Enum.each(fn {opt, i} ->
      dot = if i == selected, do: "●", else: "○"
      hint = if Map.has_key?(opt, :hint) and opt.hint, do: " \e[2m(#{opt.hint})\e[0m", else: ""

      if i == selected do
        IO.puts("\e[36m\e[1m#{@bar}  #{dot}  #{opt.label}\e[0m#{hint}")
      else
        IO.puts("\e[2m#{@bar}  #{dot}  #{opt.label}#{hint}\e[0m")
      end
    end)
  end

  # ── Multi Select (space toggle) ───────────────────────────────

  @doc """
  Space-toggle multiselect. Returns list of selected values.

  Options: list of `%{value: term, label: String.t, hint: String.t}`
  """
  def multiselect(message, options) do
    IO.puts("#{@diamond}  \e[1m#{message}\e[0m")

    prev_opts = set_raw_mode()
    checked = List.duplicate(false, length(options))

    try do
      result = multiselect_loop(options, checked, 0)

      clear_lines(length(options))
      IO.puts("")

      case result do
        {:ok, checked} ->
          selected =
            Enum.zip(options, checked)
            |> Enum.filter(fn {_, c} -> c end)
            |> Enum.map(fn {opt, _} -> opt.value end)

          labels =
            Enum.zip(options, checked)
            |> Enum.filter(fn {_, c} -> c end)
            |> Enum.map(fn {opt, _} -> opt.label end)
            |> Enum.join(", ")

          IO.write("\e[A\e[2K")
          completed(message, if(labels == "", do: "none", else: labels))
          selected

        :cancel ->
          IO.puts("\e[2m#{@bar}  Skipped\e[0m")
          []
      end
    after
      restore_mode(prev_opts)
    end
  end

  defp multiselect_loop(options, checked, cursor) do
    draw_multiselect_options(options, checked, cursor)

    case read_key() do
      :up ->
        new = if cursor > 0, do: cursor - 1, else: length(options) - 1
        clear_lines(length(options))
        multiselect_loop(options, checked, new)

      :down ->
        new = if cursor < length(options) - 1, do: cursor + 1, else: 0
        clear_lines(length(options))
        multiselect_loop(options, checked, new)

      :space ->
        new_checked = List.replace_at(checked, cursor, !Enum.at(checked, cursor))
        clear_lines(length(options))
        multiselect_loop(options, new_checked, cursor)

      :enter ->
        {:ok, checked}

      :escape ->
        :cancel

      _ ->
        multiselect_loop(options, checked, cursor)
    end
  end

  defp draw_multiselect_options(options, checked, cursor) do
    Enum.with_index(options)
    |> Enum.each(fn {opt, i} ->
      is_checked = Enum.at(checked, i, false)
      box = if is_checked, do: "◼", else: "◻"
      hint = if Map.has_key?(opt, :hint) and opt.hint, do: " \e[2m(#{opt.hint})\e[0m", else: ""

      if i == cursor do
        IO.puts("\e[36m\e[1m#{@bar}  #{box}  #{opt.label}\e[0m#{hint}")
      else
        style = if is_checked, do: "\e[32m", else: "\e[2m"
        IO.puts("#{style}#{@bar}  #{box}  #{opt.label}#{hint}\e[0m")
      end
    end)
  end

  # ── Text Input ────────────────────────────────────────────────

  @doc """
  Text input with optional masking and default value.

  Options:
  - `:default` — default value (shown, accepted on Enter)
  - `:mask` — if true, show dots instead of characters
  """
  def text(message, opts \\ []) do
    default = Keyword.get(opts, :default, "")
    mask = Keyword.get(opts, :mask, false)

    IO.puts("#{@diamond}  \e[1m#{message}\e[0m")

    # Use standard IO.gets for text input (supports paste)
    display_default = if default != "", do: " \e[2m(#{default})\e[0m", else: ""
    prompt = "\e[2m#{@bar}\e[0m  "

    raw = IO.gets(prompt) |> to_string() |> String.trim()
    value = if raw == "" and default != "", do: default, else: raw

    # Show completed state
    display = if mask, do: mask_string(value), else: value
    # clear the input line
    IO.write("\e[A\e[2K")
    IO.puts("\e[2m#{@bar}  #{display}\e[0m")

    value
  end

  # ── Confirm ───────────────────────────────────────────────────

  @doc "Yes/No confirmation. Returns boolean."
  def confirm(message, opts \\ []) do
    default = Keyword.get(opts, :default, true)

    IO.puts("#{@diamond}  \e[1m#{message}\e[0m")

    prev_opts = set_raw_mode()
    # 0=Yes, 1=No
    selected = if default, do: 0, else: 1

    try do
      result = confirm_loop(selected)

      clear_lines(1)
      IO.puts("")

      case result do
        {:ok, val} ->
          IO.write("\e[A\e[2K")
          completed(message, if(val, do: "Yes", else: "No"))
          val

        :cancel ->
          false
      end
    after
      restore_mode(prev_opts)
    end
  end

  defp confirm_loop(selected) do
    yes_style = if selected == 0, do: "\e[32m\e[1m● Yes\e[0m", else: "\e[2m○ Yes\e[0m"
    no_style = if selected == 1, do: "\e[31m\e[1m● No\e[0m", else: "\e[2m○ No\e[0m"
    IO.write("\e[2K\e[2m#{@bar}\e[0m  #{yes_style} / #{no_style}")

    case read_key() do
      key when key in [:left, :right, :up, :down] ->
        IO.write("\r")
        confirm_loop(if(selected == 0, do: 1, else: 0))

      :enter ->
        IO.puts("")
        {:ok, selected == 0}

      :escape ->
        IO.puts("")
        :cancel

      _ ->
        confirm_loop(selected)
    end
  end

  # ── Spinner ───────────────────────────────────────────────────

  @doc "Show a spinner. Returns a function to stop it."
  def spinner(label) do
    frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    parent = self()

    pid =
      spawn_link(fn ->
        spinner_loop(frames, 0, label, parent)
      end)

    # Return stop function
    fn result_text ->
      send(pid, :stop)
      IO.write("\r\e[2K")
      IO.puts(result_text)
    end
  end

  defp spinner_loop(frames, idx, label, parent) do
    frame = Enum.at(frames, rem(idx, length(frames)))
    IO.write("\r\e[2K\e[33m#{frame}\e[0m  #{label}")

    receive do
      :stop -> :ok
    after
      80 -> spinner_loop(frames, idx + 1, label, parent)
    end
  end

  # ── Raw Terminal Mode ─────────────────────────────────────────

  defp set_raw_mode do
    # Save current settings and switch to raw mode
    # On Unix, use stty; on Erlang, use io options
    case :os.type() do
      {:unix, _} ->
        {old_stty, 0} = System.cmd("stty", ["-g"], stderr_to_stdout: true)
        System.cmd("stty", ["raw", "-echo", "min", "1"], stderr_to_stdout: true)
        {:stty, String.trim(old_stty)}

      _ ->
        # Windows / other — fall back to basic IO
        :no_raw
    end
  end

  defp restore_mode({:stty, old_settings}) do
    System.cmd("stty", [old_settings], stderr_to_stdout: true)
  end

  defp restore_mode(:no_raw), do: :ok

  defp read_key do
    case IO.getn("", 1) do
      "\e" ->
        case IO.getn("", 1) do
          "[" ->
            case IO.getn("", 1) do
              "A" -> :up
              "B" -> :down
              "C" -> :right
              "D" -> :left
              _ -> :unknown
            end

          _ ->
            :escape
        end

      "\r" ->
        :enter

      "\n" ->
        :enter

      " " ->
        :space

      "\d" ->
        :backspace

      "\x7f" ->
        :backspace

      <<3>> ->
        :ctrl_c

      c when is_binary(c) ->
        {:char, c}

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp clear_lines(n) when n > 0 do
    Enum.each(1..n, fn _ ->
      # move up + clear line
      IO.write("\e[A\e[2K")
    end)
  end

  defp clear_lines(_), do: :ok

  defp mask_string(str) when byte_size(str) <= 8, do: "••••"

  defp mask_string(str) do
    String.slice(str, 0, 4) <> "..." <> String.slice(str, -4, 4)
  end
end
