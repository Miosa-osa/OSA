defmodule OptimalSystemAgent.Tools.Builtins.SendUserFileTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.SendUserFile.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    # Create a real temp file for execute tests
    tmp = Path.join(System.tmp_dir!(), "osa_send_user_file_test_#{System.unique_integer()}.txt")
    File.write!(tmp, "hello from test\n")
    on_exit(fn -> File.rm(tmp) end)
    {:ok, ctx: UseContext.empty(), tmp: tmp}
  end

  # ── Constants ────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'send_user_file'" do
      assert Constants.tool_name() == "send_user_file"
    end

    test "inline_size_limit_bytes is positive" do
      assert Constants.inline_size_limit_bytes() > 0
    end

    test "previewable_extensions includes .txt and .md" do
      assert ".txt" in Constants.previewable_extensions()
      assert ".md" in Constants.previewable_extensions()
    end

    test "event_type is :system_event" do
      assert Constants.event_type() == :system_event
    end

    test "subtype is 'send_user_file'" do
      assert Constants.subtype() == "send_user_file"
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2" do
    test "accepts minimal valid input (path only)", %{ctx: ctx, tmp: tmp} do
      assert {:ok, %{"path" => ^tmp}} = Handler.validate(%{"path" => tmp}, ctx)
    end

    test "expands relative-looking path", %{ctx: ctx} do
      # Path.expand will prepend cwd — just check it returns an absolute path (starts with /)
      assert {:ok, %{"path" => expanded}} = Handler.validate(%{"path" => "some/file.txt"}, ctx)
      assert String.starts_with?(expanded, "/")
    end

    test "accepts path with label and description", %{ctx: ctx, tmp: tmp} do
      assert {:ok, input} =
               Handler.validate(
                 %{"path" => tmp, "label" => "My Report", "description" => "Export data"},
                 ctx
               )

      assert input["label"] == "My Report"
    end

    test "rejects blank path", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => "  "}, ctx)
      assert msg =~ "blank"
    end

    test "rejects non-string label", %{ctx: ctx, tmp: tmp} do
      assert {:error, _, -32_602} = Handler.validate(%{"path" => tmp, "label" => 42}, ctx)
    end

    test "rejects non-string description", %{ctx: ctx, tmp: tmp} do
      assert {:error, _, -32_602} =
               Handler.validate(%{"path" => tmp, "description" => [:bad]}, ctx)
    end

    test "rejects missing path", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(nil, ctx)
    end
  end

  # ── Handler.check_permissions/2 ─────────────────────────────────────

  describe "check_permissions/2" do
    test "allows file under tmp dir", %{ctx: ctx, tmp: tmp} do
      assert {:allow, _} = Handler.check_permissions(%{"path" => tmp}, ctx)
    end

    test "allows file under home dir", %{ctx: ctx} do
      home_file = Path.join(System.user_home!(), "osa_test_dummy.txt")
      assert {:allow, _} = Handler.check_permissions(%{"path" => home_file}, ctx)
    end

    test "denies path outside home and tmp", %{ctx: ctx} do
      assert {:deny, msg} = Handler.check_permissions(%{"path" => "/etc/passwd"}, ctx)
      assert msg =~ "Access denied"
    end
  end

  # ── Handler.execute/2 ────────────────────────────────────────────────

  describe "execute/2" do
    test "ok result for existing readable file", %{ctx: ctx, tmp: tmp} do
      # Bus.emit is fire-and-forget; we just assert the result shape
      result = Handler.execute(%{"path" => tmp, "label" => "TestFile"}, ctx)
      assert match?({:ok, _}, result)
    end

    test "ok result message contains the label", %{ctx: ctx, tmp: tmp} do
      {:ok, msg} = Handler.execute(%{"path" => tmp, "label" => "MyLabel"}, ctx)
      assert msg =~ "MyLabel"
    end

    test "ok result message contains file size indicator", %{ctx: ctx, tmp: tmp} do
      {:ok, msg} = Handler.execute(%{"path" => tmp}, ctx)
      assert msg =~ "B" or msg =~ "KB" or msg =~ "MB"
    end

    test "returns error for non-existent file", %{ctx: ctx} do
      result =
        Handler.execute(%{"path" => "/tmp/osa_no_such_file_#{System.unique_integer()}.txt"}, ctx)

      assert {:error, _} = result
    end

    test "returns error for directory path", %{ctx: ctx} do
      result = Handler.execute(%{"path" => "/tmp"}, ctx)
      assert {:error, _} = result
    end
  end

  # ── Tool callbacks ───────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name is 'send_user_file'" do
      assert Tool.name() == "send_user_file"
    end

    test "should_defer? is true" do
      assert Tool.should_defer?()
    end

    test "concurrency_safe? is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only? is false (emits user-side event)" do
      refute Tool.read_only?(%{}, UseContext.empty())
    end

    test "destructive? is false" do
      refute Tool.destructive?(%{}, UseContext.empty())
    end

    test "open_world? is false" do
      refute Tool.open_world?(%{}, UseContext.empty())
    end

    test "safety is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "description cross-references send_message" do
      assert Tool.description() =~ "send_message"
    end

    test "aliases include 'share_file'" do
      assert "share_file" in Tool.aliases()
    end

    test "parameters require path" do
      assert "path" in Tool.parameters()["required"]
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use renders kind:send_user_file with path" do
      result = UI.render(:tool_use, %{"path" => "/tmp/report.csv", "label" => "Report"}, [])
      assert result.kind == "send_user_file"
      assert result.path == "/tmp/report.csv"
      assert result.label == "Report"
    end

    test "tool_use defaults label to basename when not provided" do
      result = UI.render(:tool_use, %{"path" => "/tmp/report.csv"}, [])
      assert result.label == "report.csv"
    end

    test "tool_result renders kind:send_user_file_result" do
      assert %{kind: "send_user_file_result"} = UI.render(:tool_result, "sent", [])
    end

    test "error renders kind:send_user_file_error" do
      assert %{kind: "send_user_file_error"} = UI.render(:error, "fail", [])
    end
  end
end
