defmodule OptimalSystemAgent.Tools.Builtins.StructuralEditTest do
  @moduledoc """
  `structural_edit` (H1): a safe structural / multi-file edit tool so the
  model has an anchored, all-or-reports alternative to hand-rolling a regex
  sweep across files.

  Not `async: true` — one describe block toggles the global
  `:post_edit_verify` app env (mirrors `Verify.PostEditTest`'s own convention).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.FSCheckpoint.Hook, as: CheckpointHook
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Tools.Builtins.StructuralEdit.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.ConflictScope
  alias OptimalSystemAgent.Tools.UseContext

  # "test" is FileState's / DriftGuard's read-before-edit exempt sentinel —
  # these tests exercise structural_edit's classification/atomicity/reporting,
  # not read-before-edit (that has its own enforcement suite).
  defp ctx, do: %UseContext{session_id: "test"}

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "osa_structural_edit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  # ---------------------------------------------------------------------------
  # Tool identity
  # ---------------------------------------------------------------------------

  describe "Tool identity" do
    test "name returns structural_edit" do
      assert Tool.name() == "structural_edit"
    end

    test "name matches Constants.tool_name" do
      assert Tool.name() == Constants.tool_name()
    end

    test "aliases include safe_multi_edit" do
      assert "safe_multi_edit" in Tool.aliases()
    end

    test "always_load? is true" do
      assert Tool.always_load?() == true
    end

    test "concurrency_safe? is false" do
      assert Tool.concurrency_safe?(%{}, ctx()) == false
    end

    test "destructive? is true" do
      assert Tool.destructive?(%{}, ctx()) == true
    end

    test "read_only? is false" do
      assert Tool.read_only?(%{}, ctx()) == false
    end

    test "parameters declare edits, pattern, and verify" do
      params = Tool.parameters()
      assert Map.has_key?(params["properties"], "edits")
      assert Map.has_key?(params["properties"], "pattern")
      assert Map.has_key?(params["properties"], "verify")
    end

    test "to_classifier_input reports every target path from both shapes" do
      input = %{
        "edits" => [%{"path" => "a.ex", "old_string" => "x", "new_string" => "y"}],
        "pattern" => %{"old_string" => "p", "new_string" => "q", "paths" => ["b.ex", "c.ex"]}
      }

      assert %{paths: paths, count: 3} = Tool.to_classifier_input(input)
      assert Enum.sort(paths) == Enum.sort(["a.ex", "b.ex", "c.ex"])
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.validate/2
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "neither edits nor pattern is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "edits" and msg =~ "pattern"
    end

    test "valid edits list passes" do
      edits = [%{"path" => "/tmp/a.txt", "old_string" => "foo", "new_string" => "bar"}]
      assert {:ok, _} = Handler.validate(%{"edits" => edits}, ctx())
    end

    test "valid pattern passes" do
      pattern = %{"old_string" => "foo", "new_string" => "bar", "paths" => ["/tmp/a.txt"]}
      assert {:ok, _} = Handler.validate(%{"pattern" => pattern}, ctx())
    end

    test "empty paths in pattern is rejected" do
      pattern = %{"old_string" => "foo", "new_string" => "bar", "paths" => []}
      assert {:error, msg, -32_602} = Handler.validate(%{"pattern" => pattern}, ctx())
      assert msg =~ "pattern"
    end

    test "non-string entry in edits is rejected" do
      edits = [%{"path" => "/tmp/a.txt", "old_string" => 1, "new_string" => "bar"}]
      assert {:error, _msg, -32_602} = Handler.validate(%{"edits" => edits}, ctx())
    end

    test "both edits and pattern together is accepted" do
      edits = [%{"path" => "/tmp/a.txt", "old_string" => "foo", "new_string" => "bar"}]
      pattern = %{"old_string" => "x", "new_string" => "y", "paths" => ["/tmp/b.txt"]}
      assert {:ok, _} = Handler.validate(%{"edits" => edits, "pattern" => pattern}, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.all_target_paths/1 — merges both shapes
  # ---------------------------------------------------------------------------

  describe "Handler.all_target_paths/1" do
    test "combines edits and pattern.paths" do
      input = %{
        "edits" => [%{"path" => "a.ex", "old_string" => "x", "new_string" => "y"}],
        "pattern" => %{"old_string" => "p", "new_string" => "q", "paths" => ["b.ex", "c.ex"]}
      }

      assert Enum.sort(Handler.all_target_paths(input)) == Enum.sort(["a.ex", "b.ex", "c.ex"])
    end

    test "pattern-only input is not invisible" do
      input = %{"pattern" => %{"old_string" => "p", "new_string" => "q", "paths" => ["x.ex"]}}
      assert Handler.all_target_paths(input) == ["x.ex"]
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.check_permissions/2
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "edits targeting a blocked path is denied" do
      edits = [%{"path" => "/etc/hosts", "old_string" => "x", "new_string" => "y"}]
      assert {:deny, msg} = Handler.check_permissions(%{"edits" => edits}, ctx())
      assert msg =~ "Access denied"
    end

    test "pattern targeting a blocked path is denied" do
      pattern = %{"old_string" => "x", "new_string" => "y", "paths" => ["/etc/hosts"]}
      assert {:deny, msg} = Handler.check_permissions(%{"pattern" => pattern}, ctx())
      assert msg =~ "Access denied"
    end

    test "targets under /tmp are allowed" do
      path = "/tmp/se_perm_test_#{:rand.uniform(100_000)}.txt"
      pattern = %{"old_string" => "x", "new_string" => "y", "paths" => [path]}
      assert {:allow, _} = Handler.check_permissions(%{"pattern" => pattern}, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Permissions — shared safety-net wiring (out_of_scope_write / bypass_immune_ask)
  # ---------------------------------------------------------------------------

  describe "Permissions shared safety net sees pattern-only calls" do
    test "out_of_scope_write flags a foreign path reachable only via pattern.paths" do
      args = %{
        "pattern" => %{"old_string" => "x", "new_string" => "y", "paths" => ["/etc/hosts"]}
      }

      assert Permissions.out_of_scope_write("structural_edit", args) == "/etc/hosts"
    end

    test "bypass_immune_ask flags .git reachable only via pattern.paths" do
      args = %{
        "pattern" => %{"old_string" => "x", "new_string" => "y", "paths" => [".git/config"]}
      }

      assert is_binary(Permissions.bypass_immune_ask("structural_edit", args))
    end

    test "a workspace-local path via pattern is not flagged" do
      args = %{"pattern" => %{"old_string" => "x", "new_string" => "y", "paths" => ["lib/a.ex"]}}
      assert Permissions.out_of_scope_write("structural_edit", args) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.execute/2 — pattern applied across a file SET
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 — pattern applies to every clean match" do
    test "applies the same anchored edit across N files, atomically" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.ex")
        b = Path.join(dir, "b.ex")
        c = Path.join(dir, "c.ex")
        File.write!(a, "before alpha_thing after\n")
        File.write!(b, "before beta_thing after\n")
        File.write!(c, "before gamma_thing after\n")

        pattern = %{
          "old_string" => "before",
          "new_string" => "AFTER_RENAME",
          "paths" => [a, b, c]
        }

        assert {:ok, summary, %{count: 3}} = Handler.execute(%{"pattern" => pattern}, ctx())
        assert summary =~ "Applied 3 edits"

        assert File.read!(a) == "AFTER_RENAME alpha_thing after\n"
        assert File.read!(b) == "AFTER_RENAME beta_thing after\n"
        assert File.read!(c) == "AFTER_RENAME gamma_thing after\n"
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "Handler.execute/2 — heterogeneous edits list" do
    test "applies distinct old/new pairs per file" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "hello world")
        File.write!(b, "foo bar baz")

        edits = [
          %{"path" => a, "old_string" => "hello", "new_string" => "goodbye"},
          %{"path" => b, "old_string" => "foo", "new_string" => "qux"}
        ]

        assert {:ok, summary, %{count: 2}} = Handler.execute(%{"edits" => edits}, ctx())
        assert summary =~ "Applied 2 edits"
        assert File.read!(a) == "goodbye world"
        assert File.read!(b) == "qux bar baz"
      after
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The core safety guarantee: non-unique / absent anchors are REPORTED, never
  # silently applied — and nothing is written when even one target is dirty.
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 — conflict (non-unique anchor) is reported, not applied" do
    test "an ambiguous match in ONE file fails the whole set and touches nothing" do
      dir = tmp_dir()

      try do
        clean = Path.join(dir, "clean.ex")
        ambiguous = Path.join(dir, "ambiguous.ex")
        File.write!(clean, "marker_v1 only once\n")
        File.write!(ambiguous, "marker_v1 here and marker_v1 again\n")

        pattern = %{
          "old_string" => "marker_v1",
          "new_string" => "marker_v2",
          "paths" => [clean, ambiguous]
        }

        assert {:error, reason} = Handler.execute(%{"pattern" => pattern}, ctx())

        # Reported, with enough detail to act on: which file, which reason.
        assert reason =~ "conflict"
        assert reason =~ ambiguous
        # The file that WOULD have applied cleanly is named too, distinctly.
        assert reason =~ clean

        # Never silently applied to the ambiguous file, and — because this is
        # an all-or-reports SET — the clean file is untouched as well.
        assert File.read!(clean) == "marker_v1 only once\n"
        assert File.read!(ambiguous) == "marker_v1 here and marker_v1 again\n"
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "Handler.execute/2 — no_match (absent anchor) is reported, not applied" do
    test "a missing anchor in ONE file fails the whole set and touches nothing" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "alpha content")
        File.write!(b, "beta content")

        edits = [
          %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
          # Absent in b.txt.
          %{"path" => b, "old_string" => "NOPE", "new_string" => "BETA"}
        ]

        assert {:error, reason} = Handler.execute(%{"edits" => edits}, ctx())
        assert reason =~ "no_match"
        assert reason =~ b

        assert File.read!(a) == "alpha content"
        assert File.read!(b) == "beta content"
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "Handler.execute/2 — already-applied is a success no-op" do
    test "every target already in the requested state is reported as success, not an error" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "ALREADY_NEW content")
        File.write!(b, "ALREADY_NEW other")

        pattern = %{
          "old_string" => "ALREADY_OLD",
          "new_string" => "ALREADY_NEW",
          "paths" => [a, b]
        }

        assert {:ok, summary, %{count: 0}} = Handler.execute(%{"pattern" => pattern}, ctx())
        assert summary =~ "No changes needed"
        assert File.read!(a) == "ALREADY_NEW content"
        assert File.read!(b) == "ALREADY_NEW other"
      after
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Apply-phase atomicity (mirrors MultiFileEdit.AtomicTest)
  # ---------------------------------------------------------------------------

  describe "apply-phase atomicity" do
    test "an unwritable target aborts the batch with no file modified" do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.txt")
        b = Path.join(dir, "b.txt")
        File.write!(a, "alpha\n")
        File.write!(b, "beta\n")

        File.chmod!(b, 0o444)

        # Skip when running as root, which ignores file permissions.
        if File.write(b, "probe") == :ok do
          File.write!(b, "beta\n")
          :skipped
        else
          pattern_edits = [
            %{"path" => a, "old_string" => "alpha", "new_string" => "ALPHA"},
            %{"path" => b, "old_string" => "beta", "new_string" => "BETA"}
          ]

          assert {:error, reason} = Handler.execute(%{"edits" => pattern_edits}, ctx())
          assert reason =~ "no files were modified"

          assert File.read!(a) == "alpha\n"
          assert File.read!(b) == "beta\n"
        end
      after
        File.chmod(Path.join(dir, "b.txt"), 0o600)
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Optional verify
  # ---------------------------------------------------------------------------

  describe "verify: true" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :post_edit_verify)
      Application.put_env(:optimal_system_agent, :post_edit_verify, enabled: true)
      on_exit(fn -> Application.put_env(:optimal_system_agent, :post_edit_verify, prev) end)
      :ok
    end

    test "reports clean when the touched file still parses" do
      dir = tmp_dir()

      try do
        path = Path.join(dir, "clean.ex")
        File.write!(path, "defmodule Clean do\n  def old_name, do: :ok\nend\n")

        edits = [%{"path" => path, "old_string" => "old_name", "new_string" => "new_name"}]
        assert {:ok, summary, _} = Handler.execute(%{"edits" => edits, "verify" => true}, ctx())

        assert summary =~ "Verification"
        assert summary =~ "no issues found"
        assert File.read!(path) =~ "new_name"
      after
        File.rm_rf!(dir)
      end
    end

    test "surfaces a syntax error the edit introduced, without rolling it back" do
      dir = tmp_dir()

      try do
        path = Path.join(dir, "broken.ex")
        File.write!(path, "defmodule Broken do\n  def ok_name, do: :ok\nend\n")

        # The replacement text itself breaks Elixir syntax (drops the `end`
        # that closes the module — unbalanced do/end).
        edits = [
          %{
            "path" => path,
            "old_string" => "def ok_name, do: :ok\nend",
            "new_string" => "def ok_name, do: :ok"
          }
        ]

        assert {:ok, summary, _} = Handler.execute(%{"edits" => edits, "verify" => true}, ctx())

        # The write already landed — verify is advisory, never a rollback —
        # and the resulting file genuinely does not parse.
        new_content = File.read!(path)
        assert new_content =~ "def ok_name, do: :ok"
        assert match?({:error, _}, Code.string_to_quoted(new_content))
        assert summary =~ "Verification found issues"
        assert summary =~ Path.basename(path)
      after
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # FSCheckpoint.Hook — /rollback coverage for both input shapes
  # ---------------------------------------------------------------------------

  describe "FSCheckpoint.Hook.extract_paths/2" do
    test "structural_edit is a destructive tool" do
      assert "structural_edit" in OptimalSystemAgent.FSCheckpoint.Config.destructive_tools()
    end

    test "yields every existing target from edits", %{} do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.ex")
        b = Path.join(dir, "b.ex")
        File.write!(a, "x\n")
        File.write!(b, "y\n")

        edits = [%{"path" => a}, %{"path" => b}, %{"path" => Path.join(dir, "missing.ex")}]

        assert Enum.sort(CheckpointHook.extract_paths("structural_edit", %{"edits" => edits})) ==
                 Enum.sort([a, b])
      after
        File.rm_rf!(dir)
      end
    end

    test "yields every existing target from a pattern-only call", %{} do
      dir = tmp_dir()

      try do
        a = Path.join(dir, "a.ex")
        File.write!(a, "x\n")

        pattern = %{"old_string" => "x", "new_string" => "y", "paths" => [a]}
        assert CheckpointHook.extract_paths("structural_edit", %{"pattern" => pattern}) == [a]
      after
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ConflictScope — a pattern-only call must not be an invisible writer
  # ---------------------------------------------------------------------------

  describe "ConflictScope.for_call/3" do
    test "two structural_edit calls to the SAME pattern-only path conflict" do
      dir = tmp_dir()

      try do
        p = Path.join(dir, "same.ex")

        scope = fn ->
          ConflictScope.for_call(
            "structural_edit",
            %{"pattern" => %{"old_string" => "a", "new_string" => "b", "paths" => [p]}},
            false
          )
        end

        a = scope.()
        b = scope.()
        assert a.mode == :scoped
        assert ConflictScope.conflict?(a, b)
      after
        File.rm_rf!(dir)
      end
    end

    test "structural_edit calls to DIFFERENT paths (edits vs pattern) do not conflict" do
      dir = tmp_dir()

      try do
        a_path = Path.join(dir, "a.ex")
        b_path = Path.join(dir, "b.ex")

        a =
          ConflictScope.for_call(
            "structural_edit",
            %{"edits" => [%{"path" => a_path, "old_string" => "x", "new_string" => "y"}]},
            false
          )

        b =
          ConflictScope.for_call(
            "structural_edit",
            %{"pattern" => %{"old_string" => "x", "new_string" => "y", "paths" => [b_path]}},
            false
          )

        assert a.mode == :scoped
        assert b.mode == :scoped
        refute ConflictScope.conflict?(a, b)
      after
        File.rm_rf!(dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # UI renders
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test ":tool_use reports combined file_count" do
      input = %{
        "edits" => [%{"path" => "/tmp/a.txt", "old_string" => "x", "new_string" => "y"}],
        "pattern" => %{"old_string" => "p", "new_string" => "q", "paths" => ["/tmp/b.txt"]}
      }

      map = UI.render(:tool_use, input, [])
      assert map[:kind] == "structural_edit"
      assert map[:file_count] == 2
    end

    test ":tool_result with {result, metadata} includes count and results" do
      meta = %{count: 1, results: [%{path: "a.ex", lines_changed: 1}]}
      map = UI.render(:tool_result, {"Applied 1 edit", meta}, [])
      assert map[:kind] == "structural_edit_result"
      assert map[:count] == 1
      assert is_list(map[:results])
    end

    test ":rejected returns kind structural_edit_rejected" do
      assert %{kind: "structural_edit_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind structural_edit_error" do
      map = UI.render(:error, "oops", [])
      assert map[:kind] == "structural_edit_error"
      assert map[:message] == "oops"
    end
  end
end
