defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.MatcherTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher

  describe "stage 1: exact match (fast path)" do
    test "replaces an exact unique substring" do
      assert {:ok, "hello WORLD\n", 1, :exact} =
               Matcher.replace("hello world\n", "world", "WORLD", false)
    end

    test "ambiguous exact match without replace_all is rejected" do
      assert {:error, :ambiguous, 2} = Matcher.replace("a a\n", "a", "b", false)
    end

    test "replace_all replaces every exact occurrence" do
      assert {:ok, "b b\n", 2, :exact} = Matcher.replace("a a\n", "a", "b", true)
    end

    test "not found returns :not_found" do
      assert {:error, :not_found} = Matcher.replace("abc", "xyz", "q", false)
    end
  end

  describe "stage 2: line-ending fuzzy match" do
    test "matches when the file uses CRLF but old_string uses LF" do
      content = "def foo do\r\n  :ok\r\nend\r\n"
      old = "def foo do\n  :ok\nend"
      new = "def foo do\n  :error\nend"

      assert {:ok, result, 1, :line_endings} = Matcher.replace(content, old, new, false)
      assert result =~ ":error"
      refute result =~ ":ok"
    end
  end

  describe "stage 3: whitespace fuzzy match (indentation preserved in output)" do
    test "matches despite trailing-whitespace drift" do
      content = "  line_one   \n  line_two\t\n"
      old = "line_one\nline_two"
      new = "REPLACED"

      # The file indents by 2 and `old_string` does not, so the replacement is
      # shifted to the file's indentation. This assertion used to be
      # "REPLACED\n" — the whitespace stage matched by ignoring indentation and
      # then wrote the model's (absent) indentation over the file's, silently
      # de-indenting the region. See `Matcher`'s moduledoc.
      assert {:ok, "  REPLACED\n", 1, :whitespace} = Matcher.replace(content, old, new, false)
    end

    test "matches a multi-line block despite leading-whitespace drift, inserting new_string verbatim" do
      # The model dropped the indentation on the second line, so it is NOT an
      # exact substring — only the whitespace stage can match it.
      content = "if x:\n    do_thing()\n"
      old = "if x:\ndo_thing()"
      # new_string carries its own indentation; the matcher does not reflow.
      new = "if x:\n    do_other()"

      assert {:ok, "if x:\n    do_other()\n", 1, :whitespace} =
               Matcher.replace(content, old, new, false)
    end

    test "ambiguous fuzzy match without replace_all is rejected" do
      content = "target  \ntarget\t\n"
      old = "target"
      assert {:error, :ambiguous, 2} = Matcher.replace(content, old, "x", false)
    end
  end

  describe "cascade ordering" do
    test "exact match wins over a would-be fuzzy match" do
      # Both an exact and a whitespace-fuzzy candidate exist; exact is preferred.
      assert {:ok, _result, 1, :exact} = Matcher.replace("foo\nfoo \n", "foo\nfoo ", "bar", false)
    end
  end
end
