defmodule OptimalSystemAgent.Agent.AppraiserTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Appraiser

  describe "estimate/2" do
    test "returns correct structure" do
      result = Appraiser.estimate(5, :backend)

      assert is_map(result)
      assert Map.has_key?(result, :complexity)
      assert Map.has_key?(result, :role)
      assert Map.has_key?(result, :role_label)
      assert Map.has_key?(result, :estimated_hours)
      assert Map.has_key?(result, :hourly_rate)
      assert Map.has_key?(result, :estimated_cost_usd)
      assert Map.has_key?(result, :confidence)
    end

    test "backend complexity 5 returns expected values" do
      result = Appraiser.estimate(5, :backend)

      assert result.complexity == 5
      assert result.role == :backend
      assert result.role_label == "Backend Engineer"
      assert result.estimated_hours == 4.0
      assert result.hourly_rate == 120
      assert result.estimated_cost_usd == 480.0
    end

    test "clamps complexity below 1 to 1" do
      result = Appraiser.estimate(0, :backend)

      assert result.complexity == 1
      assert result.estimated_hours == 0.25
    end

    test "clamps complexity above 10 to 10" do
      result = Appraiser.estimate(15, :backend)

      assert result.complexity == 10
      assert result.estimated_hours == 80.0
    end

    test "confidence decreases with complexity" do
      low = Appraiser.estimate(1, :backend)
      mid = Appraiser.estimate(5, :backend)
      high = Appraiser.estimate(10, :backend)

      assert low.confidence > mid.confidence
      assert mid.confidence > high.confidence
    end

    test "unknown role falls back to default rate" do
      result = Appraiser.estimate(3, :unknown_role)

      assert result.role_label == "Unknown"
      assert result.hourly_rate == 100
    end
  end

  describe "estimate_task/1" do
    test "aggregates correctly" do
      sub_tasks = [
        %{complexity: 3, role: :backend},
        %{complexity: 5, role: :frontend}
      ]

      result = Appraiser.estimate_task(sub_tasks)

      assert result.count == 2
      assert length(result.sub_tasks) == 2

      # backend complexity 3: 1.0h * $120 = $120
      # frontend complexity 5: 4.0h * $110 = $440
      assert result.total_hours == 5.0
      assert result.total_cost_usd == 560.0
      assert is_float(result.avg_confidence)
    end

    test "handles empty list" do
      result = Appraiser.estimate_task([])

      assert result.count == 0
      assert result.sub_tasks == []
      assert result.total_hours == 0.0
      assert result.total_cost_usd == 0.0
      assert result.avg_confidence == 0.0
    end

    test "uses defaults for missing keys in sub_tasks" do
      result = Appraiser.estimate_task([%{}])

      # Defaults: complexity 5, role :backend
      assert result.count == 1
      assert hd(result.sub_tasks).complexity == 5
      assert hd(result.sub_tasks).role == :backend
    end
  end
end
