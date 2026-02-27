defmodule OptimalSystemAgent.Skills.Builtins.FileEditTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Skills.Builtins.FileEdit

  # ── Unique replacement (happy path) ──────────────────────────────

  describe "unique replacement" do
    test "replaces unique string in file" do
      path = "/tmp/osa_test_edit_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "hello world\nfoo bar\nbaz qux\n")
        assert {:ok, msg} = FileEdit.execute(%{"path" => path, "old_string" => "foo bar", "new_string" => "replaced"})
        assert msg =~ "Replaced in"
        assert File.read!(path) == "hello world\nreplaced\nbaz qux\n"
      after
        File.rm(path)
      end
    end

    test "preserves surrounding content" do
      path = "/tmp/osa_test_edit_preserve_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "line1\nTARGET\nline3\n")
        FileEdit.execute(%{"path" => path, "old_string" => "TARGET", "new_string" => "REPLACED"})
        content = File.read!(path)
        assert content == "line1\nREPLACED\nline3\n"
      after
        File.rm(path)
      end
    end

    test "handles multiline old_string" do
      path = "/tmp/osa_test_edit_multi_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "a\nb\nc\nd\n")
        assert {:ok, _} = FileEdit.execute(%{"path" => path, "old_string" => "b\nc", "new_string" => "B\nC"})
        assert File.read!(path) == "a\nB\nC\nd\n"
      after
        File.rm(path)
      end
    end
  end

  # ── Non-unique old_string (error) ────────────────────────────────

  describe "non-unique old_string" do
    test "returns error with count when old_string appears multiple times" do
      path = "/tmp/osa_test_edit_dup_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "foo\nfoo\nfoo\n")
        assert {:error, msg} = FileEdit.execute(%{"path" => path, "old_string" => "foo", "new_string" => "bar"})
        assert msg =~ "3 times"
        assert msg =~ "must be unique"
      after
        File.rm(path)
      end
    end
  end

  # ── old_string not found ─────────────────────────────────────────

  describe "old_string not found" do
    test "returns error when old_string is absent" do
      path = "/tmp/osa_test_edit_nf_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "hello world\n")
        assert {:error, msg} = FileEdit.execute(%{"path" => path, "old_string" => "not here", "new_string" => "x"})
        assert msg =~ "not found"
      after
        File.rm(path)
      end
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────

  describe "edge cases" do
    test "empty old_string returns error" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/tmp/anything.txt", "old_string" => "", "new_string" => "x"})
      assert msg =~ "empty"
    end

    test "identical old/new returns error" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/tmp/anything.txt", "old_string" => "same", "new_string" => "same"})
      assert msg =~ "identical"
    end

    test "missing parameters returns error" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/tmp/x.txt"})
      assert msg =~ "Missing required"
    end

    test "nonexistent file returns error" do
      assert {:error, msg} = FileEdit.execute(%{
        "path" => "/tmp/osa_nonexistent_#{:rand.uniform(100_000)}.txt",
        "old_string" => "x",
        "new_string" => "y"
      })
      assert msg =~ "not found"
    end
  end

  # ── Security: blocked paths ──────────────────────────────────────

  describe "blocked paths" do
    test "editing /etc/shadow is blocked" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/etc/shadow", "old_string" => "x", "new_string" => "y"})
      assert msg =~ "Access denied"
    end

    test "editing ~/.ssh/id_rsa is blocked" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "~/.ssh/id_rsa", "old_string" => "x", "new_string" => "y"})
      assert msg =~ "Access denied"
    end

    test "editing /usr/ paths is blocked" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/usr/local/bin/test", "old_string" => "x", "new_string" => "y"})
      assert msg =~ "Access denied"
    end

    test "editing ~/.bashrc is blocked (dotfile outside ~/.osa/)" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "~/.bashrc", "old_string" => "x", "new_string" => "y"})
      assert msg =~ "Access denied"
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────

  describe "skill metadata" do
    test "name returns file_edit" do
      assert FileEdit.name() == "file_edit"
    end

    test "parameters returns valid JSON schema" do
      params = FileEdit.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "path")
      assert Map.has_key?(params["properties"], "old_string")
      assert Map.has_key?(params["properties"], "new_string")
    end

    test "description mentions surgical replacement" do
      assert FileEdit.description() =~ "surgical"
    end
  end
end
