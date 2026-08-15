defmodule OptimalSystemAgent.Tools.Builtins.FileEditTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileEdit

  # ── Unique replacement (happy path) ──────────────────────────────

  describe "unique replacement" do
    test "replaces unique string in file" do
      path = "/tmp/osa_test_edit_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "hello world\nfoo bar\nbaz qux\n")
        # FileEdit returns {:ok, content, metadata} on success; accept the
        # 3-tuple shape the structured layout produces.
        result =
          FileEdit.execute(%{
            "path" => path,
            "old_string" => "foo bar",
            "new_string" => "replaced"
          })

        msg = elem(result, 1)
        assert elem(result, 0) == :ok
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

        result =
          FileEdit.execute(%{"path" => path, "old_string" => "b\nc", "new_string" => "B\nC"})

        assert elem(result, 0) == :ok
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

        assert {:error, msg} =
                 FileEdit.execute(%{"path" => path, "old_string" => "foo", "new_string" => "bar"})

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

        assert {:error, msg} =
                 FileEdit.execute(%{
                   "path" => path,
                   "old_string" => "not here",
                   "new_string" => "x"
                 })

        assert msg =~ "not found"
      after
        File.rm(path)
      end
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────

  describe "edge cases" do
    test "empty old_string returns error" do
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "/tmp/anything.txt",
                 "old_string" => "",
                 "new_string" => "x"
               })

      assert msg =~ "empty"
    end

    test "identical old/new returns error" do
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "/tmp/anything.txt",
                 "old_string" => "same",
                 "new_string" => "same"
               })

      assert msg =~ "identical"
    end

    test "missing parameters returns error" do
      assert {:error, msg} = FileEdit.execute(%{"path" => "/tmp/x.txt"})
      assert msg =~ "Missing required"
    end

    test "nonexistent file returns error" do
      assert {:error, msg} =
               FileEdit.execute(%{
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
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "/etc/shadow",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "Access denied"
    end

    test "editing ~/.ssh/id_rsa is blocked" do
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "~/.ssh/id_rsa",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "Access denied"
    end

    test "editing /usr/ paths is blocked" do
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "/usr/local/bin/test",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "Access denied"
    end

    test "editing ~/.bashrc is blocked (dotfile outside ~/.osa/)" do
      assert {:error, msg} =
               FileEdit.execute(%{
                 "path" => "~/.bashrc",
                 "old_string" => "x",
                 "new_string" => "y"
               })

      assert msg =~ "Access denied"
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────

  # ── The diff a fuzzy edit reports back ───────────────────────────
  #
  # `format_diff` used to locate its hunk by scanning for the first line in the
  # file CONTAINING the first line of old_string, falling back to line 1 when
  # nothing matched. On a fuzzy match — the only path that still renders a diff
  # — old_string does not appear verbatim, so that scan routinely anchored on an
  # unrelated region and printed real code from it. 50 assistant turns across 21
  # corpus sessions call the result "misleading", "garbled" or "landed in the
  # wrong place", several of them paying a full file re-read to recover.

  describe "fuzzy-match diff" do
    setup do
      path = "/tmp/osa_edit_fuzzydiff_#{:rand.uniform(100_000)}.py"

      # `SENTINEL_DECOY` is what the old anchor would have found: the first line
      # of old_string ("    def apply(self):") also occurs near the TOP of the
      # file, far from the region actually edited.
      File.write!(path, """
      class Early:
          def apply(self):
              return "SENTINEL_DECOY"

      #{String.duplicate("# filler\n", 40)}
      class Target:
          def apply(self):
              return "SENTINEL_TARGET"
      """)

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "the hunk describes the region that changed, not a look-alike", %{path: path} do
      # Trailing whitespace on every line forces the `:whitespace` fuzzy stage.
      old = "    def apply(self):   \n        return \"SENTINEL_TARGET\"   "

      result =
        FileEdit.execute(%{
          "path" => path,
          "old_string" => old,
          "new_string" => "    def apply(self):\n        return \"SENTINEL_REPLACED\""
        })

      out =
        case result do
          {:ok, text, _meta} -> text
          {:ok, text} -> text
        end

      assert out =~ "fuzzy"
      assert out =~ "SENTINEL_REPLACED"
      # The decoy near the top of the file must not appear in the hunk at all.
      refute out =~ "SENTINEL_DECOY"
      assert File.read!(path) =~ "SENTINEL_REPLACED"
      assert File.read!(path) =~ "SENTINEL_DECOY"
    end

    test "an exact match still reports one line and no diff", %{path: path} do
      result =
        FileEdit.execute(%{
          "path" => path,
          "old_string" => "SENTINEL_TARGET",
          "new_string" => "SENTINEL_EXACT"
        })

      out =
        case result do
          {:ok, text, _meta} -> text
          {:ok, text} -> text
        end

      refute out =~ "@@"
      assert out =~ "Replaced in"
    end
  end

  # ── Tool metadata ────────────────────────────────────────────────
  describe "tool metadata" do
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

    # The pinned word "surgical" was retired (competitor-techniques.md §7.3):
    # it was decorative, and pinning a decorative word froze the first line of
    # the description against the routing rewrite that had to happen there.
    # What is pinned now is the ROUTING, which is the part with a consequence.
    test "description routes anchor-shaped changes to file_transform" do
      desc = FileEdit.description()
      assert desc =~ "file_transform"
      assert desc =~ ~r/anchor/i
      refute desc =~ "surgical"
    end
  end
end
