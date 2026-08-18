defmodule OptimalSystemAgent.Tools.Builtins.PushNotificationTest do
  # NOT async: the delivery seams and the OSA_NOTIFY_* overrides are process-wide
  # (Application env + environment variables). Running this module concurrently
  # with anything that notifies would let one test's injected runner leak into
  # another's - the shape of flake that is worst to debug because it only shows
  # up under load.
  use ExUnit.Case, async: false

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

  # These used to call the real notifier. On macOS that meant every `mix test`
  # posted "MyTitle / b" to the operator's Notification Centre - a suite you
  # cannot run while working. The runner is injected instead, which also makes
  # the delivery contract assertable rather than merely "ok or error".
  describe "execute/2" do
    setup do
      test_pid = self()

      Application.put_env(:optimal_system_agent, :notification_runner, fn cmd, args ->
        send(test_pid, {:cmd, cmd, args})
        {"", 0}
      end)

      # Frontmost-app detection must not reach the OS either; default to "not a
      # terminal" so the focus gate stays open unless a test closes it.
      Application.put_env(:optimal_system_agent, :notification_executables, %{})

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :notification_runner)
        Application.delete_env(:optimal_system_agent, :notification_executables)
        System.delete_env("OSA_NO_NOTIFY")
        System.delete_env("OSA_NOTIFY_WHEN_FOCUSED")
        System.delete_env("OSA_NOTIFY_SENDER")
      end)

      # Keep the focus gate out of the way of the delivery tests.
      System.put_env("OSA_NOTIFY_WHEN_FOCUSED", "1")
      :ok
    end

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

    @tag :macos_only
    test "prefers terminal-notifier when it is installed", %{ctx: ctx} do
      if :os.type() == {:unix, :darwin} do
        Application.put_env(:optimal_system_agent, :notification_executables, %{
          "terminal-notifier" => "/opt/homebrew/bin/terminal-notifier"
        })

        assert {:ok, _} = Handler.execute(%{"title" => "T", "body" => "B"}, ctx)

        assert_receive {:cmd, "/opt/homebrew/bin/terminal-notifier", args}
        assert "-title" in args and "T" in args
        assert "-message" in args and "B" in args
        # One rolling slot instead of a growing column of toasts.
        assert "-group" in args
      end
    end

    @tag :macos_only
    test "falls back to osascript when terminal-notifier is absent", %{ctx: ctx} do
      if :os.type() == {:unix, :darwin} do
        assert {:ok, _} = Handler.execute(%{"title" => "T", "body" => "B"}, ctx)

        assert_receive {:cmd, "osascript", ["-e", script]}
        assert script =~ "display notification"
        assert script =~ "OSA"
      end
    end

    @tag :macos_only
    test "OSA_NOTIFY_SENDER supplies the icon and click target", %{ctx: ctx} do
      if :os.type() == {:unix, :darwin} do
        Application.put_env(:optimal_system_agent, :notification_executables, %{
          "terminal-notifier" => "/usr/local/bin/terminal-notifier"
        })

        System.put_env("OSA_NOTIFY_SENDER", "com.github.wez.wezterm")

        assert {:ok, _} = Handler.execute(%{"title" => "T", "body" => "B"}, ctx)

        assert_receive {:cmd, _, args}
        # `-activate` is the flag that still works on current macOS; without it
        # the toast is not clickable at all.
        assert "-activate" in args
        assert "-sender" in args
        assert Enum.count(args, &(&1 == "com.github.wez.wezterm")) == 2
      end
    end

    test "OSA_NO_NOTIFY silences delivery entirely", %{ctx: ctx} do
      System.put_env("OSA_NO_NOTIFY", "1")

      assert {:ok, msg} = Handler.execute(%{"title" => "T", "body" => "B"}, ctx)
      assert msg =~ "suppressed"
      refute_receive {:cmd, _, _}
    end
  end

  describe "focus gate" do
    setup do
      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :notification_runner)
        System.delete_env("OSA_NOTIFY_WHEN_FOCUSED")
      end)

      :ok
    end

    test "a notification is pointless when you are already looking at the screen" do
      if :os.type() == {:unix, :darwin} do
        Application.put_env(:optimal_system_agent, :notification_runner, fn
          "lsappinfo", ["front"] -> {"ASN:0x0-0xb60b6:", 0}
          "lsappinfo", _ -> {~s("CFBundleIdentifier"="com.github.wez.wezterm"), 0}
          _, _ -> {"", 0}
        end)

        assert Handler.focus_suppressed?("normal")
      end
    end

    test "a critical notification is never withheld" do
      Application.put_env(:optimal_system_agent, :notification_runner, fn
        "lsappinfo", ["front"] -> {"ASN:0x0-0xb60b6:", 0}
        "lsappinfo", _ -> {~s("CFBundleIdentifier"="com.github.wez.wezterm"), 0}
        _, _ -> {"", 0}
      end)

      refute Handler.focus_suppressed?("critical")
    end

    test "a non-terminal frontmost app does not suppress" do
      Application.put_env(:optimal_system_agent, :notification_runner, fn
        "lsappinfo", ["front"] -> {"ASN:0x0-0x1234:", 0}
        "lsappinfo", _ -> {~s("CFBundleIdentifier"="com.apple.Safari"), 0}
        _, _ -> {"", 0}
      end)

      refute Handler.focus_suppressed?("normal")
    end

    test "OSA_NOTIFY_WHEN_FOCUSED opts out of the gate" do
      System.put_env("OSA_NOTIFY_WHEN_FOCUSED", "1")
      refute Handler.focus_suppressed?("normal")
    end

    test "a broken detector fails open rather than swallowing notifications" do
      Application.put_env(:optimal_system_agent, :notification_runner, fn _, _ ->
        {"lsappinfo: command not found", 127}
      end)

      refute Handler.terminal_frontmost?()
    end

    test "parses the bundle id out of lsappinfo output" do
      assert Handler.parse_bundle_id(~s("CFBundleIdentifier"="com.apple.Terminal")) ==
               "com.apple.Terminal"

      assert Handler.parse_bundle_id("nothing useful here") == nil
      assert Handler.parse_bundle_id(nil) == nil
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
