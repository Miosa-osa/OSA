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

        assert {:ok, result} =
                 FileGrep.execute(%{
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

  # ── Coverage the caller can see ──────────────────────────────────
  #
  # The corpus failure these cover: a search that examined part of the tree
  # reported "No matches found." exactly like one that examined all of it. 285
  # of 862 corpus `file_grep` calls returned that string; 58 were followed
  # within six calls by a shell grep for the same token that DID find matches.
  # The pure-Elixir path — which served every one of those 118 sessions, because
  # ripgrep was not on the BEAM's PATH — additionally dropped `context_lines`,
  # matched a bare `glob` at the top level only, and cut its file list off at
  # 500 without saying so.

  describe "coverage the caller can see" do
    setup do
      dir = "/tmp/osa_grep_cov_#{:rand.uniform(100_000)}"
      File.mkdir_p!(Path.join([dir, "src", "deep"]))
      File.mkdir_p!(Path.join([dir, "node_modules", "leftpad"]))

      File.write!(
        Path.join([dir, "src", "deep", "a.py"]),
        "one\ntwo\ndef resolve_target():\nfour\nfive\n"
      )

      File.write!(Path.join([dir, "node_modules", "leftpad", "b.py"]), "def only_in_deps():\n")
      File.write!(Path.join(dir, ".hidden_config"), "SENTINEL_TOKEN=1\n")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a bare glob matches at any depth, not just the top level", %{dir: dir} do
      assert {:ok, out} =
               FileGrep.execute(%{"pattern" => "resolve_target", "path" => dir, "glob" => "*.py"})

      assert out =~ "src/deep/a.py"
    end

    test "context_lines are actually returned", %{dir: dir} do
      assert {:ok, out} =
               FileGrep.execute(%{
                 "pattern" => "resolve_target",
                 "path" => dir,
                 "context_lines" => 2
               })

      assert out =~ ~r/a\.py-2-two/
      assert out =~ ~r/a\.py:3:def resolve_target/
      assert out =~ ~r/a\.py-4-four/
    end

    test "a hidden dotfile is searched", %{dir: dir} do
      assert {:ok, out} = FileGrep.execute(%{"pattern" => "SENTINEL_TOKEN", "path" => dir})
      assert out =~ ".hidden_config"
    end

    test "a match only in a dependency directory is found and labelled", %{dir: dir} do
      assert {:ok, out} = FileGrep.execute(%{"pattern" => "only_in_deps", "path" => dir})

      assert out =~ "node_modules/leftpad/b.py"
      assert out =~ "dependency or build directories"
    end

    test "an ordinary match skips dependency directories and carries no note", %{dir: dir} do
      assert {:ok, out} = FileGrep.execute(%{"pattern" => "resolve_target", "path" => dir})

      assert out =~ "src/deep/a.py"
      refute out =~ "dependency or build directories"
    end

    test "a genuinely absent pattern says the widened search covered everything", %{dir: dir} do
      assert {:ok, out} = FileGrep.execute(%{"pattern" => "zzz_absent_zzz", "path" => dir})

      assert out =~ "No matches found."
      assert out =~ "DID widen"
      refute out =~ "Coverage limit"
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
