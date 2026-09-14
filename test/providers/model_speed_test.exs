defmodule OptimalSystemAgent.Providers.ModelSpeedTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.ModelSpeed

  setup do
    ModelSpeed.reset()
    on_exit(fn -> ModelSpeed.reset() end)
  end

  describe "key/2" do
    test "namespaces by provider so the same model id under different providers never collides" do
      assert ModelSpeed.key(:surplus, "claude-opus-5") == "surplus/claude-opus-5"
      assert ModelSpeed.key(:anthropic, "claude-opus-5") == "anthropic/claude-opus-5"

      assert ModelSpeed.key(:surplus, "claude-opus-5") !=
               ModelSpeed.key(:anthropic, "claude-opus-5")
    end

    test "downcases the model id (case-insensitive, matches SurplusModels' convention)" do
      assert ModelSpeed.key(:surplus, "Claude-Opus-5") == "surplus/claude-opus-5"
    end
  end

  describe "get/2 with no data" do
    test "returns nil for a model that has never been recorded" do
      assert ModelSpeed.get(:surplus, "never-seen-model") == nil
    end
  end

  describe "record/3 + get/2 — EMA math" do
    test "the first sample is returned as-is" do
      ModelSpeed.record(:surplus, "deepseek-v4-flash", 116.6)
      assert ModelSpeed.get(:surplus, "deepseek-v4-flash") == 116.6
    end

    test "a second sample is blended toward the newest value, not overwritten or averaged evenly" do
      ModelSpeed.record(:surplus, "ministral-3-3b-instruct", 100.0)
      ModelSpeed.record(:surplus, "ministral-3-3b-instruct", 200.0)

      # alpha = 0.3: 0.3 * 200 + 0.7 * 100 = 130.0
      assert_in_delta ModelSpeed.get(:surplus, "ministral-3-3b-instruct"), 130.0, 0.001
    end

    test "repeated identical samples converge to that value" do
      Enum.each(1..20, fn _ -> ModelSpeed.record(:surplus, "stable-model", 50.0) end)
      assert_in_delta ModelSpeed.get(:surplus, "stable-model"), 50.0, 0.01
    end

    test "a non-positive or non-numeric tok_s is silently ignored" do
      assert ModelSpeed.record(:surplus, "bad-model", 0) == :ok
      assert ModelSpeed.record(:surplus, "bad-model", -5.0) == :ok
      assert ModelSpeed.record(:surplus, "bad-model", "not a number") == :ok
      assert ModelSpeed.get(:surplus, "bad-model") == nil
    end

    test "different providers for the same bare model id are tracked independently" do
      ModelSpeed.record(:surplus, "claude-opus-5", 300.0)
      ModelSpeed.record(:anthropic, "claude-opus-5", 60.0)

      assert ModelSpeed.get(:surplus, "claude-opus-5") == 300.0
      assert ModelSpeed.get(:anthropic, "claude-opus-5") == 60.0
    end
  end

  describe "persistence — survives the in-memory cache being cleared" do
    test "a recorded value round-trips through the SQLite table, not just persistent_term" do
      ModelSpeed.record(:surplus, "roundtrip-model", 88.0)

      # Simulate a fresh BEAM boot: wipe BOTH the in-memory EMA cache and the
      # "table already warmed" flag, so the next `get/2` is forced back
      # through `ensure_table!/0`'s `load_into_cache/0` — proving the value
      # came from the DB row `record/3` wrote, not a cache that merely
      # survived untouched.
      :persistent_term.put({ModelSpeed, :ema}, %{})
      :persistent_term.put({ModelSpeed, :table_ready}, false)

      assert ModelSpeed.get(:surplus, "roundtrip-model") == 88.0
    end
  end
end
