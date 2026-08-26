defmodule OptimalSystemAgent.Channels.CLI.LineEditorSelectionTest do
  @moduledoc """
  Text selection in the CLI input box (#121).

  Without selection there is no way to grab a block of text and delete it, so
  editing a long line means walking the cursor with arrow keys and deleting one
  character at a time.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.CLI.LineEditor, as: LE

  defp buf(s), do: String.graphemes(s)

  describe "selection range" do
    test "spans between anchor and cursor" do
      assert LE.selection_range(2, 7) == {2, 5}
    end

    test "a leftward drag selects the same span as a rightward one" do
      # The anchor may sit on either side; normalising here is what stops a
      # backwards drag from selecting nothing (or the wrong half).
      assert LE.selection_range(7, 2) == LE.selection_range(2, 7)
    end

    test "no selection when nothing is dragged" do
      assert LE.selection_range(nil, 5) == nil
      assert LE.selection_range(4, 4) == nil
    end
  end

  describe "deleting a selection" do
    test "removes exactly the selected span" do
      {out, cursor} = LE.delete_selection(buf("hello world"), 6, 11)
      assert Enum.join(out) == "hello "
      assert cursor == 6
    end

    test "deletes the same span when dragged backwards" do
      {a, _} = LE.delete_selection(buf("hello world"), 6, 11)
      {b, _} = LE.delete_selection(buf("hello world"), 11, 6)
      assert Enum.join(a) == Enum.join(b)
    end

    test "the cursor lands where the text used to start" do
      # So that typing immediately replaces the selection.
      {_out, cursor} = LE.delete_selection(buf("abcdefgh"), 2, 6)
      assert cursor == 2
    end

    test "deletes from the middle without touching either side" do
      # The bug this pins: splitting on the wrong half deletes the text on the
      # other side of the selection.
      {out, _} = LE.delete_selection(buf("keep[cut]keep"), 4, 9)
      assert Enum.join(out) == "keepkeep"
    end

    test "works across a newline" do
      {out, _} = LE.delete_selection(buf("one\ntwo\nthree"), 2, 9)
      assert Enum.join(out) == "onhree"
    end

    test "no selection leaves the buffer untouched" do
      original = buf("unchanged")
      assert {^original, 4} = LE.delete_selection(original, nil, 4)
    end
  end

  describe "splitting for reverse-video rendering" do
    test "yields before, selected and after" do
      assert {"hello ", "world", ""} = LE.selection_split("hello world", 6, 11)
    end

    test "a middle selection keeps both sides" do
      assert {"ab", "cd", "ef"} = LE.selection_split("abcdef", 2, 4)
    end

    test "no selection renders as plain text" do
      assert {"abcdef", "", ""} = LE.selection_split("abcdef", nil, 3)
    end

    test "a backwards drag renders the same span" do
      assert LE.selection_split("abcdef", 4, 2) == LE.selection_split("abcdef", 2, 4)
    end
  end

  describe "reverse-video rendering" do
    test "wraps only the selected characters" do
      assert ["ab\e[7mcd\e[27mef"] = LE.decorate_lines("abcdef", 2, 4)
    end

    test "plain lines when nothing is selected" do
      assert ["abcdef"] = LE.decorate_lines("abcdef", nil, 3)
    end

    test "a selection crossing a newline re-opens per line" do
      # One region opened before the newline would leave the attribute on
      # across the break and paint the continuation prefix as selected.
      lines = LE.decorate_lines("one\ntwo", 1, 6)

      assert length(lines) == 2

      assert Enum.all?(lines, &String.contains?(&1, "\e[7m")),
             "a line was not re-opened: #{inspect(lines)}"

      assert Enum.all?(lines, &String.contains?(&1, "\e[27m")),
             "a line was left open: #{inspect(lines)}"
    end

    test "lines outside the selection are untouched" do
      lines = LE.decorate_lines("aaa\nbbb\nccc", 0, 3)

      assert Enum.at(lines, 1) == "bbb"
      assert Enum.at(lines, 2) == "ccc"
    end

    test "every attribute opened is closed" do
      # An unbalanced pair leaves the whole rest of the terminal inverted.
      for {a, c} <- [{0, 3}, {2, 9}, {1, 11}] do
        joined = "one\ntwo\nthree" |> LE.decorate_lines(a, c) |> Enum.join("\n")
        opens = joined |> String.split("\e[7m") |> length()
        closes = joined |> String.split("\e[27m") |> length()
        assert opens == closes, "unbalanced for #{a}..#{c}: #{inspect(joined)}"
      end
    end

    test "a backwards drag highlights the same span" do
      assert LE.decorate_lines("abcdef", 4, 2) == LE.decorate_lines("abcdef", 2, 4)
    end
  end
end
