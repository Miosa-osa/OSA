defmodule OptimalSystemAgent.Config.DotenvTest do
  @moduledoc """
  A byte-order mark is not whitespace.

  `String.trim/1` removes whitespace; U+FEFF is Unicode category Cf (format).
  A `.env` written by a Windows editor — and OSA ships a Windows build, so
  this is a supported way to produce the file — starts `EF BB BF`, and every
  reader on the credential path used to parse its first line as the key
  `"﻿ANTHROPIC_API_KEY"`. The key was set under a name nothing reads, and
  OSA reported "no API key configured" while the user was looking at the key
  in the file.

  Invisible in every editor, affects only the FIRST entry, and reports as a
  missing credential rather than a parse error.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Config.Dotenv

  @bom "﻿"

  describe "byte-order marks" do
    test "a BOM-prefixed file yields the real key name, not a look-alike" do
      pairs = Dotenv.parse(@bom <> "ANTHROPIC_API_KEY=sk-ant-123\nOPENAI_API_KEY=sk-openai\n")

      assert {"ANTHROPIC_API_KEY", "sk-ant-123"} in pairs,
             "the first key of a Windows-authored .env must parse under its real name"

      refute Enum.any?(pairs, fn {k, _} -> String.contains?(k, @bom) end),
             "no key may carry an invisible codepoint that makes lookups miss"
    end

    test "the BOM'd key is genuinely equal to the plain one" do
      [{bomd, _}] = Dotenv.parse(@bom <> "ANTHROPIC_API_KEY=x")
      [{plain, _}] = Dotenv.parse("ANTHROPIC_API_KEY=x")

      # This is the whole failure in one assertion: without stripping, these
      # two strings are different and only one of them is ever looked up.
      assert bomd == plain
    end

    test "other invisible codepoints are stripped too" do
      # A key pasted out of a web page can carry U+200B.
      assert [{"OPENAI_API_KEY", "sk-1"}] = Dotenv.parse("​OPENAI_API_KEY=sk-1")
    end

    test "strip_invisible/1 leaves ordinary content byte-identical" do
      content = "A=1\n# comment\nB=2\n"
      assert Dotenv.strip_invisible(content) == content
    end
  end

  describe "parsing rules the writers already rely on" do
    test "blank lines and comments are skipped" do
      assert [{"A", "1"}] = Dotenv.parse("\n# a comment\n\nA=1\n")
    end

    test "values containing '=' are preserved whole" do
      assert [{"URL", "https://x.test/?a=1&b=2"}] = Dotenv.parse("URL=https://x.test/?a=1&b=2")
    end

    test "surrounding quotes are removed" do
      assert [{"A", "1"}] = Dotenv.parse(~s(A="1"))
      assert [{"B", "2"}] = Dotenv.parse("B='2'")
    end

    test "the FIRST occurrence of a duplicate key wins" do
      # Mirrors the boot loader's "only set a var when it is not already
      # present" rule. If these two disagreed, a file with a duplicated key
      # would have one surface writing the value another refuses to read.
      assert [{"A", "first"}] = Dotenv.parse("A=first\nA=second\n")
    end

    test "a missing file is an empty list, not a crash" do
      assert Dotenv.parse_file("/nonexistent/osa/.env") == []
    end
  end

  describe "parse_file/1 on a real BOM'd file" do
    @tag :tmp_dir
    test "reads through the BOM", %{tmp_dir: dir} do
      path = Path.join(dir, ".env")
      File.write!(path, @bom <> "ANTHROPIC_API_KEY=sk-ant-999\n")

      assert {"ANTHROPIC_API_KEY", "sk-ant-999"} =
               path |> Dotenv.parse_file() |> List.keyfind("ANTHROPIC_API_KEY", 0)
    end
  end
end
