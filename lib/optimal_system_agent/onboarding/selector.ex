defmodule OptimalSystemAgent.Onboarding.Selector do
  @moduledoc """
  Interactive arrow-key selector for terminal UIs.

  Renders a list of options with optional group headers. The user navigates
  with arrow keys (↑/↓) and confirms with Enter. Falls back to a numbered
  prompt when raw terminal mode is unavailable (CI, piped input, Windows).

  ## Usage

      lines = [
        {:header, "Category A"},
        {:option, "Choice One", :one},
        {:option, "Choice Two", :two},
        :separator,
        {:header, "Category B"},
        {:option, "Choice Three", :three}
      ]

      Selector.select(lines)  # => :two (user's choice)
  """

  @cursor "❯ "
  @blank "  "
  @bold IO.ANSI.bright()
  @cyan IO.ANSI.cyan()
  @dim IO.ANSI.faint()
  @reset IO.ANSI.reset()
  @clear_line "\e[2K"
  @hide_cursor "\e[?25l"
  @show_cursor "\e[?25h"

  @doc """
  Display an interactive selector. Returns the selected value, or nil on cancel.

  `lines` is a list of:
    - `{:option, label, value}` — selectable item
    - `{:input, label, prompt}` — selectable item that drops into free-text input
    - `{:header, text}` — non-selectable header text
    - `:separator` — blank line

  `default_index` — 0-based index into the selectable options (default: 0).

  Returns:
    - `{:selected, value}` — when an `:option` item is chosen
    - `{:input, text}` — when an `:input` item is chosen and text entered
    - `nil` — on cancel
  """
  @spec select(list(), non_neg_integer()) :: {:selected, term()} | {:input, String.t()} | nil
  def select(lines, default_index \\ 0) do
    options = for item <- lines, match?({:option, _, _}, item) or match?({:input, _, _}, item), do: item

    if options == [] do
      nil
    else
      case open_tty() do
        {:ok, tty} -> select_interactive(tty, lines, options, default_index)
        {:error, _} -> select_fallback(options, default_index)
      end
    end
  end

  # ── Interactive Mode ──────────────────────────────────────────

  defp select_interactive(tty, lines, options, selected) do
    saved = save_stty()
    set_raw_mode()
    IO.write(@hide_cursor)
    total = length(lines)

    try do
      render(lines, options, selected)

      case input_loop(tty, lines, options, selected, total) do
        :cancelled ->
          clear(total)
          nil

        {:input_selected, index} ->
          item = Enum.at(options, index)
          {_, label, prompt} = item
          clear(total)
          IO.puts("  #{@cyan}#{@cursor}#{label}#{@reset}")

          # Restore terminal for line input
          IO.write(@show_cursor)
          restore_stty(saved)
          close_tty(tty)

          # Read free-text input
          case IO.gets("  #{prompt} ") do
            :eof -> nil
            text ->
              trimmed = String.trim(text)
              if trimmed == "", do: nil, else: {:input, trimmed}
          end

        index ->
          item = Enum.at(options, index)
          case item do
            {:option, label, value} ->
              clear(total)
              IO.puts("  #{@cyan}#{@cursor}#{label}#{@reset}")
              {:selected, value}

            {:input, label, prompt} ->
              clear(total)
              IO.puts("  #{@cyan}#{@cursor}#{label}#{@reset}")
              IO.write(@show_cursor)
              restore_stty(saved)
              close_tty(tty)

              case IO.gets("  #{prompt} ") do
                :eof -> nil
                text ->
                  trimmed = String.trim(text)
                  if trimmed == "", do: nil, else: {:input, trimmed}
              end
          end
      end
    after
      # Safe cleanup — may already be restored for :input paths
      IO.write(@show_cursor)
      try do restore_stty(saved) rescue _ -> :ok end
      try do close_tty(tty) rescue _ -> :ok end
    end
  end

  defp input_loop(tty, lines, options, selected, total) do
    max = length(options) - 1

    case read_key(tty) do
      :up when selected > 0 ->
        new = selected - 1
        rerender(lines, options, new, total)
        input_loop(tty, lines, options, new, total)

      :down when selected < max ->
        new = selected + 1
        rerender(lines, options, new, total)
        input_loop(tty, lines, options, new, total)

      :enter ->
        case Enum.at(options, selected) do
          {:input, _, _} -> {:input_selected, selected}
          _ -> selected
        end

      :ctrl_c ->
        :cancelled

      _ ->
        input_loop(tty, lines, options, selected, total)
    end
  end

  # ── Rendering ─────────────────────────────────────────────────

  defp render(lines, options, selected) do
    IO.write(build_frame(lines, options, selected))
  end

  defp rerender(lines, options, selected, total) do
    IO.write(["\e[#{total}A" | build_frame(lines, options, selected)])
  end

  defp clear(total) do
    IO.write("\e[#{total}A")
    IO.write(List.duplicate("#{@clear_line}\n", total))
    IO.write("\e[#{total}A")
  end

  defp build_frame(lines, options, selected) do
    selected_item = Enum.at(options, selected)
    # Extract a comparable key from the selected item
    selected_key = item_key(selected_item)

    Enum.map(lines, fn
      {:option, label, value} ->
        if {:option, value} == selected_key do
          "#{@clear_line}  #{@bold}#{@cyan}#{@cursor}#{label}#{@reset}\n"
        else
          "#{@clear_line}  #{@blank}#{label}\n"
        end

      {:input, label, _prompt} ->
        if {:input, label} == selected_key do
          "#{@clear_line}  #{@bold}#{@cyan}#{@cursor}#{label}#{@reset}\n"
        else
          "#{@clear_line}  #{@blank}#{label}\n"
        end

      {:header, text} ->
        "#{@clear_line}  #{text}\n"

      :separator ->
        "#{@clear_line}\n"
    end)
  end

  defp item_key({:option, _label, value}), do: {:option, value}
  defp item_key({:input, label, _prompt}), do: {:input, label}

  # ── Terminal I/O ──────────────────────────────────────────────

  defp open_tty do
    :file.open(~c"/dev/tty", [:read, :raw, :binary])
  end

  defp close_tty(tty), do: :file.close(tty)

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
      {:ok, <<3>>} -> :ctrl_c
      {:ok, _} -> :other
      _ -> :other
    end
  end

  defp read_escape(tty) do
    case :file.read(tty, 1) do
      {:ok, <<"[">>} ->
        case :file.read(tty, 1) do
          {:ok, <<"A">>} -> :up
          {:ok, <<"B">>} -> :down
          {:ok, <<"C">>} -> :right
          {:ok, <<"D">>} -> :left
          _ -> :escape
        end

      _ ->
        :escape
    end
  end

  # ── Fallback (non-interactive) ────────────────────────────────

  defp select_fallback(options, default_index) do
    options
    |> Enum.with_index(1)
    |> Enum.each(fn {item, num} ->
      label = case item do
        {:option, l, _} -> l
        {:input, l, _} -> l
      end
      IO.puts("  #{num}. #{label}")
    end)

    default_num = default_index + 1
    max = length(options)

    case IO.gets("  > [#{default_num}]: ") do
      :eof ->
        fallback_select_item(Enum.at(options, default_index))

      input ->
        trimmed = String.trim(input)

        if trimmed == "" do
          fallback_select_item(Enum.at(options, default_index))
        else
          case Integer.parse(trimmed) do
            {n, ""} when n >= 1 and n <= max ->
              fallback_select_item(Enum.at(options, n - 1))

            _ ->
              IO.puts("  #{@dim}Invalid choice (1-#{max}). Try again.#{@reset}")
              select_fallback(options, default_index)
          end
        end
    end
  end

  defp fallback_select_item({:option, _label, value}), do: {:selected, value}

  defp fallback_select_item({:input, _label, prompt}) do
    case IO.gets("  #{prompt} ") do
      :eof -> nil
      text ->
        trimmed = String.trim(text)
        if trimmed == "", do: nil, else: {:input, trimmed}
    end
  end
end
