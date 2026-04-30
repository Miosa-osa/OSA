defmodule OptimalSystemAgent.Agent.Scheduler.CronPresetsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Scheduler.CronPresets

  describe "list_presets/0" do
    test "returns 8 presets" do
      presets = CronPresets.list_presets()
      assert length(presets) == 8
    end

    test "each preset has required fields" do
      for preset <- CronPresets.list_presets() do
        assert is_binary(preset.id)
        assert is_binary(preset.cron)
        assert is_binary(preset.label)
      end
    end

    test "preset IDs are unique" do
      ids = Enum.map(CronPresets.list_presets(), & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "describe/1" do
    test "returns label for known presets" do
      assert CronPresets.describe("* * * * *") == "Every minute"
      assert CronPresets.describe("0 * * * *") == "Every hour"
      assert CronPresets.describe("0 9 * * *") == "Daily at 9:00 AM"
      assert CronPresets.describe("0 9 * * 1") == "Weekly on Monday at 9:00 AM"
      assert CronPresets.describe("0 9 1 * *") == "Monthly on the 1st at 9:00 AM"
    end

    test "generates description for unknown expressions" do
      desc = CronPresets.describe("30 14 * * *")
      assert is_binary(desc)
      assert desc != "30 14 * * *"
    end
  end

  describe "resolve/1" do
    test "resolves preset ids to cron expressions" do
      assert {:ok, "0 * * * *"} = CronPresets.resolve("hourly")
      assert {:ok, "*/5 * * * *"} = CronPresets.resolve("every_5_minutes")
    end

    test "accepts raw cron expressions" do
      assert {:ok, "15 9 * * 1"} = CronPresets.resolve("15 9 * * 1")
    end

    test "rejects invalid schedules" do
      assert {:error, _reason} = CronPresets.resolve("definitely-not-a-schedule")
    end
  end

  describe "next_run/1" do
    test "returns a DateTime for valid expressions" do
      result = CronPresets.next_run("* * * * *")
      assert %DateTime{} = result
      assert DateTime.compare(result, DateTime.utc_now()) == :gt
    end

    test "returns nil for invalid expressions" do
      assert CronPresets.next_run("invalid") == nil
    end

    test "next run for every-minute is within 60 seconds" do
      next = CronPresets.next_run("* * * * *")
      diff = DateTime.diff(next, DateTime.utc_now(), :second)
      assert diff >= 0 and diff <= 60
    end
  end
end
