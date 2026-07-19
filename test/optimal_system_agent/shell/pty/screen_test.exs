defmodule OptimalSystemAgent.Shell.Pty.ScreenTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Shell.Pty.Screen

  defp text(bytes) do
    Screen.new(20, 5) |> Screen.feed(bytes) |> Screen.text()
  end

  test "plain text renders" do
    assert text("hello") == "hello"
  end

  test "CR/LF produce separate lines" do
    assert text("line1\r\nline2") == "line1\nline2"
  end

  test "carriage return overwrites in place" do
    # "abcdef" then CR then "XYZ" overwrites the first three cells.
    assert text("abcdef\rXYZ") == "XYZdef"
  end

  test "backspace moves the cursor back" do
    assert text("abc\b\bX") == "aXc"
  end

  test "SGR color codes are stripped from the text" do
    assert text("\e[31mred\e[0m") == "red"
  end

  test "cursor addressing (CSI H) positions writes" do
    # Home, write A; move to row 2 col 1, write B.
    assert text("\e[1;1HA\e[2;1HB") == "A\nB"
  end

  test "erase-display (CSI 2J) clears the grid" do
    assert text("garbage\e[2J") == ""
  end

  test "erase-line to end (CSI K)" do
    # Write, CR home the col, then CSI 0K erases from cursor to end of line.
    assert text("abcdef\r\e[0K") == ""
  end

  test "OSC title sequence is consumed, not rendered" do
    assert text("\e]0;my title\avisible") == "visible"
  end

  test "line feed scrolls and fills scrollback when past the bottom" do
    # 5-row screen; write 7 lines so the first 2 scroll off.
    bytes = Enum.map_join(1..7, "", fn n -> "row#{n}\r\n" end)
    s = Screen.new(20, 5) |> Screen.feed(bytes)
    sb = Screen.scrollback(s, :all)
    assert "row1" in sb
    assert "row2" in sb
    # The visible screen retains the most recent rows.
    assert Screen.text(s) =~ "row7"
  end

  test "cursor position is 1-based" do
    s = Screen.new(20, 5) |> Screen.feed("ab")
    assert Screen.cursor(s) == %{row: 1, col: 3}
  end

  test "split escape across feeds is reassembled" do
    s = Screen.new(20, 5) |> Screen.feed("A\e[") |> Screen.feed("2;1HB")
    assert Screen.text(s) == "A\nB"
  end
end
