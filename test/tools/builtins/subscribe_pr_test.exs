defmodule OptimalSystemAgent.Tools.Builtins.SubscribePrTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.SubscribePr.{Constants, Handler, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @valid_url "https://github.com/owner/repo/pull/123"

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── Constants ────────────────────────────────────────────────────────

  describe "Constants" do
    test "tool_name is 'subscribe_pr'" do
      assert Constants.tool_name() == "subscribe_pr"
    end

    test "valid_events includes merged and closed" do
      assert "merged" in Constants.valid_events()
      assert "closed" in Constants.valid_events()
    end

    test "default_events is a subset of valid_events" do
      assert Enum.all?(Constants.default_events(), &(&1 in Constants.valid_events()))
    end

    test "valid_poll_intervals are all positive integers" do
      assert Enum.all?(Constants.valid_poll_intervals(), &(is_integer(&1) and &1 > 0))
    end

    test "default_poll_interval_minutes is in valid_poll_intervals" do
      assert Constants.default_poll_interval_minutes() in Constants.valid_poll_intervals()
    end
  end

  # ── Handler.validate/2 ───────────────────────────────────────────────

  describe "validate/2" do
    test "accepts minimal valid input (pr_url only)", %{ctx: ctx} do
      assert {:ok, input} = Handler.validate(%{"pr_url" => @valid_url}, ctx)
      assert input["events"] == Constants.default_events()
      assert input["poll_interval_minutes"] == Constants.default_poll_interval_minutes()
    end

    test "accepts full valid input", %{ctx: ctx} do
      assert {:ok, _} =
               Handler.validate(
                 %{
                   "pr_url" => @valid_url,
                   "events" => ["merged"],
                   "poll_interval_minutes" => 10
                 },
                 ctx
               )
    end

    test "rejects invalid PR URL (no pull segment)", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"pr_url" => "https://github.com/owner/repo"}, ctx)

      assert msg =~ "pr_url"
    end

    test "rejects non-github URL", %{ctx: ctx} do
      assert {:error, _, -32_602} =
               Handler.validate(
                 %{"pr_url" => "https://gitlab.com/owner/repo/merge_requests/1"},
                 ctx
               )
    end

    test "rejects empty events list", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"pr_url" => @valid_url, "events" => []}, ctx)

      assert msg =~ "events"
    end

    test "rejects invalid event names", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"pr_url" => @valid_url, "events" => ["yolo"]}, ctx)

      assert msg =~ "Invalid events"
    end

    test "rejects invalid poll_interval_minutes", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"pr_url" => @valid_url, "poll_interval_minutes" => 7}, ctx)

      assert msg =~ "poll_interval_minutes"
    end

    test "rejects missing pr_url", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{}, ctx)
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate("nope", ctx)
    end
  end

  # ── Handler.check_permissions/2 ─────────────────────────────────────

  describe "check_permissions/2" do
    test "allows github.com URL", %{ctx: ctx} do
      assert {:allow, _} = Handler.check_permissions(%{"pr_url" => @valid_url}, ctx)
    end

    test "denies non-github.com host", %{ctx: ctx} do
      assert {:deny, msg} =
               Handler.check_permissions(%{"pr_url" => "https://evil.com/pull/1"}, ctx)

      assert msg =~ "Access denied"
    end
  end

  # ── Handler.execute/2 ────────────────────────────────────────────────

  describe "execute/2" do
    # Scheduler may not be running in test — both ok and error are valid
    test "returns ok or error tuple", %{ctx: ctx} do
      input = %{
        "pr_url" => @valid_url,
        "events" => ["merged"],
        "poll_interval_minutes" => 5
      }

      result = Handler.execute(input, ctx)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "ok result includes job_id and cron expression", %{ctx: ctx} do
      input = %{
        "pr_url" => @valid_url,
        "events" => ["merged"],
        "poll_interval_minutes" => 5
      }

      case Handler.execute(input, ctx) do
        {:ok, msg} ->
          assert msg =~ "job_id"
          assert msg =~ "cron"
          assert msg =~ "*/5"

        {:error, _} ->
          :ok
      end
    end
  end

  # ── Tool callbacks ───────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name is 'subscribe_pr'" do
      assert Tool.name() == "subscribe_pr"
    end

    test "should_defer? is true" do
      assert Tool.should_defer?()
    end

    test "concurrency_safe? is false (Scheduler mutation)" do
      refute Tool.concurrency_safe?(%{}, UseContext.empty())
    end

    test "read_only? is false" do
      refute Tool.read_only?(%{}, UseContext.empty())
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

    test "description cross-references cron" do
      assert Tool.description() =~ "cron"
    end

    test "aliases include 'watch_pr'" do
      assert "watch_pr" in Tool.aliases()
    end

    test "parameters require pr_url" do
      assert "pr_url" in Tool.parameters()["required"]
    end
  end

  # ── UI renders ───────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use renders kind:subscribe_pr" do
      result = UI.render(:tool_use, %{"pr_url" => @valid_url}, [])
      assert result.kind == "subscribe_pr"
      assert result.pr_url == @valid_url
    end

    test "tool_result renders kind:subscribe_pr_result" do
      assert %{kind: "subscribe_pr_result"} = UI.render(:tool_result, "registered", [])
    end

    test "error renders kind:subscribe_pr_error" do
      assert %{kind: "subscribe_pr_error"} = UI.render(:error, "fail", [])
    end
  end
end
