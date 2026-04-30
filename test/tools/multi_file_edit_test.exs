defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEditTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit, as: MultiFileEditShim
  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.{Constants, Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "mfe_test"}

  # ---------------------------------------------------------------------------
  # Structured layout — identity callbacks
  # ---------------------------------------------------------------------------

  describe "Tool identity" do
    test "name returns multi_file_edit" do
      assert Tool.name() == "multi_file_edit"
    end

    test "name matches Constants.tool_name" do
      assert Tool.name() == Constants.tool_name()
    end

    test "should_defer? is false" do
      assert Tool.should_defer?() == false
    end

    test "always_load? is true" do
      assert Tool.always_load?() == true
    end

    test "concurrency_safe? is false" do
      assert Tool.concurrency_safe?(%{}, ctx()) == false
    end

    test "read_only? is false" do
      assert Tool.read_only?(%{}, ctx()) == false
    end

    test "destructive? is true" do
      assert Tool.destructive?(%{}, ctx()) == true
    end

    test "safety is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "parameters includes required edits field" do
      params = Tool.parameters()
      assert params["required"] == ["edits"]
    end
  end

  # ---------------------------------------------------------------------------
  # Shim parity — flat module delegates to Tool
  # ---------------------------------------------------------------------------

  describe "shim parity" do
    test "MultiFileEdit.name() delegates to MultiFileEdit.Tool.name()" do
      assert MultiFileEditShim.name() == Tool.name()
    end

    test "MultiFileEdit.destructive?/2 delegates to MultiFileEdit.Tool.destructive?/2" do
      assert MultiFileEditShim.destructive?(%{}, ctx()) == Tool.destructive?(%{}, ctx())
    end

    test "MultiFileEdit has execute/2 (structured)" do
      assert {_, _} = List.keyfind(MultiFileEditShim.__info__(:functions), :execute, 0, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — validate
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "valid non-empty edits list passes" do
      edits = [%{"path" => "/tmp/a.txt", "old_string" => "foo", "new_string" => "bar"}]
      assert {:ok, _} = Handler.validate(%{"edits" => edits}, ctx())
    end

    test "empty edits list is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"edits" => []}, ctx())
      assert msg =~ "empty"
    end

    test "edits not a list is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"edits" => "nope"}, ctx())
      assert msg =~ "list"
    end

    test "missing edits key is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "edits"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — check_permissions
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "edit targeting blocked path is denied" do
      edits = [%{"path" => "/etc/hosts", "old_string" => "x", "new_string" => "y"}]
      assert {:deny, msg} = Handler.check_permissions(%{"edits" => edits}, ctx())
      assert msg =~ "Access denied"
    end

    test "edit targeting /tmp is allowed" do
      path = "/tmp/mfe_perm_test_#{:rand.uniform(100_000)}.txt"
      edits = [%{"path" => path, "old_string" => "x", "new_string" => "y"}]
      assert {:allow, _} = Handler.check_permissions(%{"edits" => edits}, ctx())
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — execute with rich 3-tuple return
  # ---------------------------------------------------------------------------

  describe "Handler.execute/2 — success path and 3-tuple return" do
    setup do
      path1 = "/tmp/mfe_test_a_#{:rand.uniform(100_000)}.txt"
      path2 = "/tmp/mfe_test_b_#{:rand.uniform(100_000)}.txt"
      File.write!(path1, "hello world")
      File.write!(path2, "foo bar baz")

      on_exit(fn ->
        File.rm(path1)
        File.rm(path2)
      end)

      {:ok, path1: path1, path2: path2}
    end

    test "returns {:ok, summary, metadata} 3-tuple on success", %{path1: p1, path2: p2} do
      edits = [
        %{"path" => p1, "old_string" => "hello", "new_string" => "goodbye"},
        %{"path" => p2, "old_string" => "foo", "new_string" => "qux"}
      ]

      result = Handler.execute(%{"edits" => edits}, ctx())

      assert {:ok, summary, metadata} = result
      assert is_binary(summary)
      assert summary =~ "2 files"
      assert is_map(metadata)
      assert metadata.count == 2
      assert is_list(metadata.results)
      assert length(metadata.results) == 2
    end

    test "metadata.results has path and lines_changed keys", %{path1: p1} do
      edits = [%{"path" => p1, "old_string" => "hello", "new_string" => "goodbye"}]
      assert {:ok, _, metadata} = Handler.execute(%{"edits" => edits}, ctx())
      [result] = metadata.results
      assert Map.has_key?(result, :path)
      assert Map.has_key?(result, :lines_changed)
    end

    test "files are actually modified on disk", %{path1: p1} do
      edits = [%{"path" => p1, "old_string" => "world", "new_string" => "BEAM"}]
      assert {:ok, _, _} = Handler.execute(%{"edits" => edits}, ctx())
      assert File.read!(p1) == "hello BEAM"
    end
  end

  describe "Handler.execute/2 — validation failures" do
    test "old_string not found returns error without touching files" do
      path = "/tmp/mfe_nofound_#{:rand.uniform(100_000)}.txt"
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      edits = [%{"path" => path, "old_string" => "NOPE", "new_string" => "bar"}]
      assert {:error, msg} = Handler.execute(%{"edits" => edits}, ctx())
      assert msg =~ "Validation failed"
      assert msg =~ "not found"
    end

    test "empty old_string returns validation error" do
      path = "/tmp/mfe_empty_#{:rand.uniform(100_000)}.txt"
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      edits = [%{"path" => path, "old_string" => "", "new_string" => "bar"}]
      assert {:error, msg} = Handler.execute(%{"edits" => edits}, ctx())
      assert msg =~ "empty"
    end

    test "identical old and new strings returns validation error" do
      path = "/tmp/mfe_same_#{:rand.uniform(100_000)}.txt"
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      edits = [%{"path" => path, "old_string" => "hello", "new_string" => "hello"}]
      assert {:error, msg} = Handler.execute(%{"edits" => edits}, ctx())
      assert msg =~ "identical"
    end

    test "file not found returns validation error" do
      edits = [
        %{
          "path" => "/tmp/definitely_missing_osa_mfe.txt",
          "old_string" => "x",
          "new_string" => "y"
        }
      ]

      assert {:error, msg} = Handler.execute(%{"edits" => edits}, ctx())
      assert msg =~ "Validation failed"
    end
  end

  # ---------------------------------------------------------------------------
  # UI renders — including 3-tuple result shape
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.UI

    test ":tool_use returns kind multi_file_edit with file_count" do
      edits = [
        %{"path" => "/tmp/a.txt", "old_string" => "x", "new_string" => "y"},
        %{"path" => "/tmp/b.txt", "old_string" => "a", "new_string" => "b"}
      ]

      map = UI.render(:tool_use, %{"edits" => edits}, [])
      assert map[:kind] == "multi_file_edit"
      assert map[:file_count] == 2
    end

    test ":tool_result with plain string returns kind multi_file_edit_result" do
      map = UI.render(:tool_result, "Edited 2 files:\n  a.txt", [])
      assert map[:kind] == "multi_file_edit_result"
      assert map[:message] == "Edited 2 files:\n  a.txt"
    end

    test ":tool_result with {result, metadata} 3-tuple includes count and results" do
      meta = %{count: 2, results: [%{path: "a.txt", lines_changed: 1}]}
      map = UI.render(:tool_result, {"Edited 2 files", meta}, [])
      assert map[:kind] == "multi_file_edit_result"
      assert map[:count] == 2
      assert is_list(map[:results])
    end

    test ":rejected returns kind multi_file_edit_rejected" do
      assert %{kind: "multi_file_edit_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind multi_file_edit_error" do
      map = UI.render(:error, "oops", [])
      assert map[:kind] == "multi_file_edit_error"
      assert map[:message] == "oops"
    end

    test "unknown stage returns nil" do
      assert UI.render(:progress, %{}, []) == nil
    end
  end
end
