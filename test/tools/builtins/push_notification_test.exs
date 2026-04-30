defmodule OptimalSystemAgent.Tools.Builtins.PushNotificationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.PushNotification.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── Constants ────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'push_notification'" do
      assert Constants.tool_name() == "push_notification"
    end

    test "valid_urgency includes normal and critical" do
      assert "normal" in Constants.valid_urgency()
      assert "critical" in Constants.valid_urgency()
    end

    test "default_urgency is 'normal'" do
      assert Constants.default_urgency() == "normal"
    end

    test "max_title_chars is positive" do
      assert Constants.max_title_chars() > 0
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2" do
    test "accepts valid title and body", %{ctx: ctx} do
      assert {:ok, _} = Handler.validate(%{"title" => "Done", "body" => "Build finished"}, ctx)
    end

    test "sets default urgency when omitted", %{ctx: ctx} do
      assert {:ok, input} = Handler.validate(%{"title" => "Done", "body" => "OK"}, ctx)
      assert input["urgency"] == Constants.default_urgency()
    end

    test "accepts explicit urgency", %{ctx: ctx} do
      assert {:ok, input} =
               Handler.validate(
                 %{"title" => "Alert", "body" => "Danger!", "urgency" => "critical"},
                 ctx
               )

      assert input["urgency"] == "critical"
    end

    test "rejects blank title", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"title" => "  ", "body" => "body"}, ctx)

      assert msg =~ "blank"
    end

    test "rejects title over max_title_chars", %{ctx: ctx} do
      long_title = String.duplicate("x", Constants.max_title_chars() + 1)

      assert {:error, msg, -32_602} =
               Handler.validate(%{"title" => long_title, "body" => "b"}, ctx)

      assert msg =~ "title"
    end

    test "rejects blank body", %{ctx: ctx} do
      assert {:error, _, -32_602} =
               Handler.validate(%{"title" => "title", "body" => ""}, ctx)
    end

    test "rejects body over max_body_chars", %{ctx: ctx} do
      long_body = String.duplicate("x", Constants.max_body_chars() + 1)

      assert {:error, msg, -32_602} =
               Handler.validate(%{"title" => "t", "body" => long_body}, ctx)

      assert msg =~ "body"
    end

    test "rejects invalid urgency", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"title" => "t", "body" => "b", "urgency" => "apocalyptic"}, ctx)

      assert msg =~ "urgency"
    end

    test "rejects missing title", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"body" => "body"}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(nil, ctx)
    end
  end

  # ── Handler.check_permissions/2 ─────────────────────────────────────

  describe "check_permissions/2" do
    test "allows normal urgency in strict mode", %{ctx: ctx} do
      strict_ctx = %UseContext{ctx | permission_mode: :strict}
      input = %{"title" => "t", "body" => "b", "urgency" => "normal"}
      assert {:allow, _} = Handler.check_permissions(input, strict_ctx)
    end

    test "denies critical urgency in strict mode" do
      strict_ctx = %UseContext{UseContext.empty() | permission_mode: :strict}
      input = %{"title" => "t", "body" => "b", "urgency" => "critical"}
      assert {:deny, msg} = Handler.check_permissions(input, strict_ctx)
      assert msg =~ "Access denied"
    end

    test "allows critical urgency in non-strict mode", %{ctx: ctx} do
      input = %{"title" => "t", "body" => "b", "urgency" => "critical"}
      assert {:allow, _} = Handler.check_permissions(input, ctx)
    end
  end

  # ── Handler.execute/2 ────────────────────────────────────────────────

  describe "execute/2" do
    # We can only assert on the shape of the return — the actual OS call
    # may or may not succeed in CI. Both success and graceful error are ok.
    test "returns ok or error tuple (platform-dependent)", %{ctx: ctx} do
      result =
        Handler.execute(%{"title" => "Test", "body" => "OSA test", "urgency" => "low"}, ctx)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "ok result contains the title", %{ctx: ctx} do
      case Handler.execute(%{"title" => "MyTitle", "body" => "b", "urgency" => "normal"}, ctx) do
        {:ok, msg} -> assert msg =~ "MyTitle"
        {:error, _} -> :ok
      end
    end
  end

  # ── Tool callbacks ───────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name is 'push_notification'" do
      assert Tool.name() == "push_notification"
    end

    test "should_defer? is true" do
      assert Tool.should_defer?()
    end

    test "read_only? is false" do
      refute Tool.read_only?(%{}, UseContext.empty())
    end

    test "concurrency_safe? is true" do
      assert Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "destructive? is false" do
      refute Tool.destructive?(%{}, UseContext.empty())
    end

    test "open_world? is true" do
      assert Tool.open_world?(%{}, UseContext.empty())
    end

    test "safety is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "description cross-references send_message" do
      assert Tool.description() =~ "send_message"
    end

    test "aliases include 'notify'" do
      assert "notify" in Tool.aliases()
    end

    test "parameters require title and body" do
      assert Tool.parameters()["required"] == ["title", "body"]
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use renders kind:push_notification with title and body" do
      result = UI.render(:tool_use, %{"title" => "T", "body" => "B", "urgency" => "normal"}, [])
      assert result.kind == "push_notification"
      assert result.title == "T"
      assert result.urgency == "normal"
    end

    test "tool_result renders kind:push_notification_result" do
      assert %{kind: "push_notification_result"} = UI.render(:tool_result, "sent", [])
    end

    test "error renders kind:push_notification_error" do
      assert %{kind: "push_notification_error"} = UI.render(:error, "fail", [])
    end
  end
end
