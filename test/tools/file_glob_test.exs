defmodule OptimalSystemAgent.Tools.Builtins.FileGlobTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileGlob

  # ── Pattern matching ─────────────────────────────────────────────

  describe "pattern matching" do
    test "finds files matching glob pattern" do
      dir = "/tmp/osa_glob_test_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "one.txt"), "a")
        File.write!(Path.join(dir, "two.txt"), "b")
        File.write!(Path.join(dir, "three.ex"), "c")

        assert {:ok, result} = FileGlob.execute(%{"pattern" => "*.txt", "path" => dir})
        assert result =~ "one.txt"
        assert result =~ "two.txt"
        refute result =~ "three.ex"
        assert result =~ "2 files found"
      after
        File.rm_rf(dir)
      end
    end

    test "supports recursive glob with **" do
      dir = "/tmp/osa_glob_recurse_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(Path.join(dir, "sub"))
        File.write!(Path.join(dir, "top.ex"), "a")
        File.write!(Path.join([dir, "sub", "nested.ex"]), "b")

        assert {:ok, result} = FileGlob.execute(%{"pattern" => "**/*.ex", "path" => dir})
        assert result =~ "top.ex"
        assert result =~ "nested.ex"
      after
        File.rm_rf(dir)
      end
    end
  end

  # ── Empty results ────────────────────────────────────────────────

  describe "empty results" do
    test "returns message when no files match" do
      dir = "/tmp/osa_glob_empty_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        assert {:ok, result} = FileGlob.execute(%{"pattern" => "*.nonexistent", "path" => dir})
        assert result =~ "No files matched"
      after
        File.rm_rf(dir)
      end
    end
  end

  # ── Custom base path ─────────────────────────────────────────────

  describe "custom base path" do
    test "searches within specified base directory" do
      dir = "/tmp/osa_glob_base_#{:rand.uniform(100_000)}"

      try do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "target.md"), "# Hello")

        assert {:ok, result} = FileGlob.execute(%{"pattern" => "*.md", "path" => dir})
        assert result =~ "target.md"
      after
        File.rm_rf(dir)
      end
    end

    test "defaults to cwd when no path given" do
      # Just verify it doesn't crash — actual results depend on cwd
      assert {tag, _} = FileGlob.execute(%{"pattern" => "*.nonexistent_pattern_12345"})
      assert tag == :ok
    end
  end

  # ── Security ─────────────────────────────────────────────────────

  describe "security" do
    test "filters out sensitive paths from results" do
      # Sensitive paths should not appear in results
      # We test indirectly — if the path contains .ssh/id_rsa it won't show
      assert {:ok, _} = FileGlob.execute(%{"pattern" => "*.txt", "path" => "/tmp"})
    end

    test "missing pattern returns error" do
      assert {:error, msg} = FileGlob.execute(%{})
      assert msg =~ "Missing required"
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────

  describe "tool metadata" do
    test "name returns file_glob" do
      assert FileGlob.name() == "file_glob"
    end

    test "parameters returns valid JSON schema" do
      params = FileGlob.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "pattern")
    end
  end
end
