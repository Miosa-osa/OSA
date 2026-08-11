defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.SpliceFidelityTest do
  @moduledoc """
  Finding 4, `matcher.ex`: the fuzzy stages matched by IGNORING something, then
  spliced the model's raw lines back in — putting that something back wrong.

  Every test here fails against the pre-fix `splice/4` and `normalizer/1`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher

  describe "line endings (matcher.ex:109 / :143-152)" do
    test "a CRLF file stays CRLF after an LF-only replacement" do
      content = "alpha\r\nbeta\r\ngamma\r\n"

      # The model supplies LF-only text spanning two lines, which is why the
      # :line_endings stage exists. Pre-fix the splice then wrote LF-only lines
      # into the CRLF file, leaving an LF island that every editor and
      # `git diff` flags, and which the next edit of the same region no longer
      # matches.
      assert {:ok, result, 1, :line_endings} =
               Matcher.replace(content, "beta\ngamma", "BETA\nGAMMA", false)

      assert result == "alpha\r\nBETA\r\nGAMMA\r\n"
      refute result =~ ~r/(?<!\r)\nBETA/
    end

    test "a multi-line CRLF replacement keeps CRLF on every inserted line" do
      content = "a\r\nb\r\nc\r\nd\r\n"

      assert {:ok, result, 1, :line_endings} =
               Matcher.replace(content, "b\nc", "x\ny\nz", false)

      assert result == "a\r\nx\r\ny\r\nz\r\nd\r\n"
    end

    test "an LF file is untouched" do
      content = "alpha\nbeta\ngamma\n"
      assert {:ok, result, 1, :exact} = Matcher.replace(content, "beta", "BETA", false)
      assert result == "alpha\nBETA\ngamma\n"
      refute result =~ "\r"
    end

    test "a carriage return in the MIDDLE of a line is not ignored" do
      # Pre-fix `String.replace(&1, "\r", "")` stripped every \r anywhere in the
      # line, not just the EOL one, so a line containing an embedded CR could be
      # matched by an old_string that does not describe it.
      content = ~s|progress = "50%\rdone"\n|
      assert {:error, :not_found} = Matcher.replace(content, ~s|progress = "50%done"|, "x", false)
    end
  end

  describe "indentation (matcher.ex:110)" do
    test "the file's own indentation is preserved, not the model's" do
      content = "    a = 1\n    b = 2\n"

      # The model believes the block is indented 2; the file uses 4. That
      # disagreement is exactly what makes the :whitespace stage fire — and
      # pre-fix the splice then wrote the model's 2-space indentation over the
      # file's 4, silently re-indenting code the edit never asked to touch
      # (fatal in Python, diff noise everywhere else).
      assert {:ok, result, 1, :whitespace} =
               Matcher.replace(content, "  a = 1\n  b = 2", "  a = 9\n  b = 8", false)

      assert result == "    a = 9\n    b = 8\n"
    end

    test "relative indentation inside the replacement survives the shift" do
      content = "class C:\n        def m(self):\n            pass\n"

      assert {:ok, result, 1, :whitespace} =
               Matcher.replace(
                 content,
                 "    def m(self):\n        pass",
                 "    def m(self):\n        return 1",
                 false
               )

      assert result == "class C:\n        def m(self):\n            return 1\n"
    end

    test "an over-indented model replacement is shifted back out" do
      content = "    a = 1\n    b = 2\n"

      assert {:ok, result, 1, :whitespace} =
               Matcher.replace(
                 content,
                 "      a = 1\n      b = 2",
                 "      a = 9\n      b = 8",
                 false
               )

      assert result == "    a = 9\n    b = 8\n"
    end

    test "blank lines are not turned into trailing whitespace" do
      content = "    a = 1\n\n    b = 2\n"

      assert {:ok, result, 1, :whitespace} =
               Matcher.replace(content, "  a = 1\n\n  b = 2", "  a = 9\n\n  b = 8", false)

      assert result == "    a = 9\n\n    b = 8\n"
      refute result =~ ~r/ +\n\n/
    end
  end

  describe "unchanged behaviour" do
    test "the exact fast path is untouched" do
      assert {:ok, "xbx", 1, :exact} = Matcher.replace("xax", "a", "b", false)
    end

    test "ambiguity is still reported" do
      assert {:error, :ambiguous, 2} = Matcher.replace("a\na\n", "a", "b", false)
    end

    test "replace_all still replaces every match" do
      assert {:ok, "b\nb\n", 2, :exact} = Matcher.replace("a\na\n", "a", "b", true)
    end
  end
end
