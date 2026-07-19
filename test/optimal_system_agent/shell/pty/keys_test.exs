defmodule OptimalSystemAgent.Shell.Pty.KeysTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Shell.Pty.Keys

  test "literal text passes through" do
    assert Keys.parse("hello") == "hello"
  end

  test "<CR> is carriage return" do
    assert Keys.parse("<CR>") == "\r"
    assert Keys.parse("<Enter>") == "\r"
  end

  test "<Esc> and <Tab> and <BS>" do
    assert Keys.parse("<Esc>") == "\e"
    assert Keys.parse("<Tab>") == "\t"
    assert Keys.parse("<BS>") == <<0x7F>>
  end

  test "<C-c> is Ctrl+C (0x03)" do
    assert Keys.parse("<C-c>") == <<3>>
  end

  test "control chords fold to C0 bytes regardless of case" do
    assert Keys.parse("<C-a>") == <<1>>
    assert Keys.parse("<C-A>") == <<1>>
    assert Keys.parse("<C-z>") == <<26>>
  end

  test "mixed text and chords" do
    assert Keys.parse("hello<CR>") == "hello\r"
    assert Keys.parse("<Esc>:wq<CR>") == "\e:wq\r"
  end

  test "arrow keys map to xterm sequences" do
    assert Keys.parse("<Up>") == "\e[A"
    assert Keys.parse("<Down>") == "\e[B"
    assert Keys.parse("<Right>") == "\e[C"
    assert Keys.parse("<Left>") == "\e[D"
  end

  test "alt chord prefixes ESC" do
    assert Keys.parse("<M-x>") == "\ex"
    assert Keys.parse("<A-b>") == "\eb"
  end

  test "literal angle-bracket helpers" do
    assert Keys.parse("<lt>") == "<"
    assert Keys.parse("<gt>") == ">"
    assert Keys.parse("<bar>") == "|"
  end

  test "unterminated < is a literal" do
    assert Keys.parse("a < b") == "a < b"
  end

  test "unknown token degrades to visible text" do
    assert Keys.parse("<Nope>") == "<Nope>"
  end
end
