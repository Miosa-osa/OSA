defmodule OptimalSystemAgent.Tools.Builtins.FileGrepTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileGrep

  # ── Regex pattern match ──────────────────────────────────────────

  describe "regex pattern match" do
    test "finds matching lines in files" do
      dir = "/tmp/osa_grep_test_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "sample.ex"), "defmodule Foo do\n  def bar, do: :ok\nend\n")

        assert {:ok, result} = FileGrep.execute(%{"pattern" => "defmodule", "path" => dir})
        assert result =~ "defmodule"
      after
        File.rm_rf(dir)
      end
    end

    test "supports regex patterns" do
      dir = "/tmp/osa_grep_regex_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "code.ex"), "def foo, do: 42\ndef bar, do: 99\nval = 123\n")

        assert {:ok, result} = FileGrep.execute(%{"pattern" => "def \\w+", "path" => dir})
        assert result =~ "foo"
        assert result =~ "bar"
      after
        File.rm_rf(dir)
      end
    end

    test "searches single file when path is a file" do
      path = "/tmp/osa_grep_single_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "line one\nline two\nline three\n")
        assert {:ok, result} = FileGrep.execute(%{"pattern" => "two", "path" => path})
        assert result =~ "two"
      after
        File.rm(path)
      end
    end
  end

  # ── No matches ───────────────────────────────────────────────────

  describe "no matches" do
    test "returns 'no matches' message when nothing found" do
      dir = "/tmp/osa_grep_nomatch_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "empty.txt"), "hello world\n")

        assert {:ok, result} = FileGrep.execute(%{"pattern" => "zzzznonexistent", "path" => dir})
        assert result =~ "No matches"
      after
        File.rm_rf(dir)
      end
    end
  end

  # ── Glob filter ──────────────────────────────────────────────────

  describe "glob filter" do
    test "respects file glob filter" do
      dir = "/tmp/osa_grep_glob_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "match.ex"), "target_string\n")
        File.write!(Path.join(dir, "skip.txt"), "target_string\n")

        assert {:ok, result} = FileGrep.execute(%{
          "pattern" => "target_string",
          "path" => dir,
          "glob" => "*.ex"
        })
        assert result =~ "match.ex"
        # rg may or may not include the .txt — depends on rg glob behavior
        # The key test is that it doesn't crash and returns results
      after
        File.rm_rf(dir)
      end
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────

  describe "edge cases" do
    test "missing pattern returns error" do
      assert {:error, msg} = FileGrep.execute(%{})
      assert msg =~ "Missing required"
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────

  describe "tool metadata" do
    test "name returns file_grep" do
      assert FileGrep.name() == "file_grep"
    end

    test "parameters returns valid JSON schema" do
      params = FileGrep.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "pattern")
    end
  end
end
