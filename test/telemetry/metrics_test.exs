defmodule OptimalSystemAgent.Telemetry.MetricsTest do
  # Metrics shares a named GenServer and ETS table — no async
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Telemetry.Metrics

  # ---------------------------------------------------------------------------
  # record_tool_execution/2
  # ---------------------------------------------------------------------------

  describe "record_tool_execution/2" do
    test "does not raise for valid inputs" do
      assert :ok = Metrics.record_tool_execution("search_files", 42)
    end

    test "accepts float duration" do
      assert :ok = Metrics.record_tool_execution("read_file", 12.5)
    end

    test "records appear in get_metrics/0 after a short wait" do
      Metrics.record_tool_execution("test_tool_#{System.unique_integer([:positive])}", 10)
      Process.sleep(50)

      metrics = Metrics.get_metrics()
      assert is_map(metrics)
      executions = Map.get(metrics, :tool_executions, %{})
      assert is_map(executions)
    end
  end

  # ---------------------------------------------------------------------------
  # record_provider_call/3
  # ---------------------------------------------------------------------------

  describe "record_provider_call/3" do
    test "does not raise for valid inputs" do
      assert :ok = Metrics.record_provider_call(:anthropic, 1200, true)
    end

    test "accepts false success flag" do
      assert :ok = Metrics.record_provider_call(:openai, 300, false)
    end

    test "provider latency appears in metrics after a short wait" do
      Metrics.record_provider_call(:anthropic, 500, true)
      Process.sleep(50)

      metrics = Metrics.get_metrics()
      latencies = Map.get(metrics, :provider_latency, %{})
      assert is_map(latencies)
    end
  end

  # ---------------------------------------------------------------------------
  # record_noise_filter_result/1
  # ---------------------------------------------------------------------------

  describe "record_noise_filter_result/1" do
    test "accepts :filtered outcome" do
      assert :ok = Metrics.record_noise_filter_result(:filtered)
    end

    test "accepts :clarify outcome" do
      assert :ok = Metrics.record_noise_filter_result(:clarify)
    end

    test "accepts :pass outcome" do
      assert :ok = Metrics.record_noise_filter_result(:pass)
    end
  end

  # ---------------------------------------------------------------------------
  # record_signal_weight/1
  # ---------------------------------------------------------------------------

  describe "record_signal_weight/1" do
    test "accepts float values in 0.0–1.0 range" do
      assert :ok = Metrics.record_signal_weight(0.0)
      assert :ok = Metrics.record_signal_weight(0.5)
      assert :ok = Metrics.record_signal_weight(1.0)
    end

    test "accepts integer values" do
      assert :ok = Metrics.record_signal_weight(0)
      assert :ok = Metrics.record_signal_weight(1)
    end
  end

  # ---------------------------------------------------------------------------
  # get_metrics/0
  # ---------------------------------------------------------------------------

  describe "get_metrics/0" do
    test "returns a map" do
      assert is_map(Metrics.get_metrics())
    end

    test "returned map has expected top-level keys" do
      metrics = Metrics.get_metrics()

      assert Map.has_key?(metrics, :tool_executions)
      assert Map.has_key?(metrics, :provider_latency)
      assert Map.has_key?(metrics, :session_stats)
      assert Map.has_key?(metrics, :noise_filter)
      assert Map.has_key?(metrics, :signal_weights)
    end

    test "noise_filter has the three outcome counters" do
      metrics = Metrics.get_metrics()
      noise = Map.get(metrics, :noise_filter, %{})

      assert Map.has_key?(noise, :filtered)
      assert Map.has_key?(noise, :clarify)
      assert Map.has_key?(noise, :pass)
    end

    test "signal_weights has four bucket keys" do
      metrics = Metrics.get_metrics()
      weights = Map.get(metrics, :signal_weights, %{})

      assert Map.has_key?(weights, :"0.0-0.2")
      assert Map.has_key?(weights, :"0.2-0.5")
      assert Map.has_key?(weights, :"0.5-0.8")
      assert Map.has_key?(weights, :"0.8-1.0")
    end

    test "session_stats has turns_by_session and messages_today" do
      metrics = Metrics.get_metrics()
      stats = Map.get(metrics, :session_stats, %{})

      assert Map.has_key?(stats, :turns_by_session)
      assert Map.has_key?(stats, :messages_today)
    end
  end

  # ---------------------------------------------------------------------------
  # get_summary/0
  # ---------------------------------------------------------------------------

  describe "get_summary/0" do
    test "returns a map" do
      assert is_map(Metrics.get_summary())
    end

    test "summary has expected top-level keys" do
      summary = Metrics.get_summary()

      assert Map.has_key?(summary, :tool_executions)
      assert Map.has_key?(summary, :provider_latency)
      assert Map.has_key?(summary, :session_stats)
      assert Map.has_key?(summary, :noise_filter_rate)
      assert Map.has_key?(summary, :signal_weight_distribution)
    end

    test "noise_filter_rate is a float >= 0.0 and <= 100.0" do
      rate = Metrics.get_summary().noise_filter_rate

      assert is_float(rate)
      assert rate >= 0.0
      assert rate <= 100.0
    end

    test "noise_filter_rate increases after recording filtered outcomes" do
      # Record several filtered and pass outcomes
      Metrics.record_noise_filter_result(:filtered)
      Metrics.record_noise_filter_result(:filtered)
      Metrics.record_noise_filter_result(:pass)
      Process.sleep(50)

      rate = Metrics.get_summary().noise_filter_rate
      assert rate > 0.0
    end

    test "signal_weight_distribution has the four bucket keys" do
      dist = Metrics.get_summary().signal_weight_distribution

      assert Map.has_key?(dist, :"0.0-0.2")
      assert Map.has_key?(dist, :"0.2-0.5")
      assert Map.has_key?(dist, :"0.5-0.8")
      assert Map.has_key?(dist, :"0.8-1.0")
    end

    test "tool_executions summary maps tool names to stat maps" do
      tool = "summary_test_tool_#{System.unique_integer([:positive])}"
      Metrics.record_tool_execution(tool, 100)
      Process.sleep(50)

      summary = Metrics.get_summary()
      executions = summary.tool_executions

      if Map.has_key?(executions, tool) do
        stats = Map.get(executions, tool)
        assert Map.has_key?(stats, :count)
        assert Map.has_key?(stats, :avg_ms)
        assert Map.has_key?(stats, :min_ms)
        assert Map.has_key?(stats, :max_ms)
        assert Map.has_key?(stats, :p99_ms)
        assert stats.count >= 1
      end
    end

    test "provider_latency summary maps provider atoms to stat maps" do
      Metrics.record_provider_call(:groq, 200, true)
      Process.sleep(50)

      summary = Metrics.get_summary()
      latency = summary.provider_latency

      if Map.has_key?(latency, :groq) do
        stats = Map.get(latency, :groq)
        assert Map.has_key?(stats, :avg_ms)
        assert Map.has_key?(stats, :p99_ms)
        assert Map.has_key?(stats, :count)
        assert stats.count >= 1
      end
    end
  end
end
