defmodule OptimalSystemAgent.Channels.NoiseFilterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.NoiseFilter

  # ---------------------------------------------------------------------------
  # check/2 — Tier 1 (regex, no signal weight)
  # ---------------------------------------------------------------------------

  describe "check/2 — tier 1 deterministic regex" do
    test "single character is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("a")
    end

    test "single 'k' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("k")
    end

    test "'ok' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("ok")
    end

    test "'okay' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("okay")
    end

    test "'sure' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("sure")
    end

    test "'yep' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("yep")
    end

    test "'lol' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("lol")
    end

    test "'haha' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("haha")
    end

    test "'hmm' is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("hmm")
    end

    test "pure punctuation is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("?!")
    end

    test "ellipsis is filtered" do
      assert {:filtered, _ack} = NoiseFilter.check("...")
    end

    test "whitespace-only string is filtered" do
      assert {:filtered, ""} = NoiseFilter.check("   ")
    end

    test "empty string after trim is filtered silently" do
      assert {:filtered, ""} = NoiseFilter.check("")
    end

    test "substantive message passes" do
      assert :pass = NoiseFilter.check("How do I set up a PostgreSQL connection pool in Elixir?")
    end

    test "technical question passes" do
      assert :pass = NoiseFilter.check("What is the best way to handle GenServer state?")
    end

    test "multi-sentence message passes" do
      assert :pass =
               NoiseFilter.check(
                 "I need to refactor the payment service. It currently has N+1 query issues."
               )
    end

    test "case-insensitive: 'OK' is filtered" do
      assert {:filtered, _} = NoiseFilter.check("OK")
    end

    test "case-insensitive: 'SURE' is filtered" do
      assert {:filtered, _} = NoiseFilter.check("SURE")
    end

    test "acknowledgment text is a non-empty string" do
      {:filtered, ack} = NoiseFilter.check("ok")
      assert is_binary(ack)
      assert byte_size(ack) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # check/2 — Tier 2 (signal weight)
  # ---------------------------------------------------------------------------

  describe "check/2 — tier 2 signal weight" do
    test "weight below definitely_noise threshold filters substantive-looking message" do
      # Even if the text is substantive, a very low weight means it's noise
      assert {:filtered, _ack} = NoiseFilter.check("yes I agree with that", 0.05)
    end

    test "weight in likely_noise range filters" do
      assert {:filtered, _ack} = NoiseFilter.check("alright that sounds good to me", 0.25)
    end

    test "weight in uncertain range returns :clarify" do
      assert {:clarify, prompt} = NoiseFilter.check("interesting approach", 0.45)
      assert is_binary(prompt)
      assert String.contains?(prompt, "interesting approach")
    end

    test "weight above uncertain threshold passes" do
      assert :pass = NoiseFilter.check("Deploy the updated service to production now", 0.80)
    end

    test "nil weight falls back to tier 1 only" do
      assert :pass = NoiseFilter.check("How do I fix the memory leak in the supervisor?", nil)
    end

    test "clarification prompt contains original message text" do
      {:clarify, prompt} = NoiseFilter.check("maybe later", 0.50)
      assert String.contains?(prompt, "maybe later")
    end
  end

  # ---------------------------------------------------------------------------
  # weight_thresholds/0
  # ---------------------------------------------------------------------------

  describe "weight_thresholds/0" do
    test "returns a map with required keys" do
      thresholds = NoiseFilter.weight_thresholds()

      assert is_map(thresholds)
      assert Map.has_key?(thresholds, :definitely_noise)
      assert Map.has_key?(thresholds, :likely_noise)
      assert Map.has_key?(thresholds, :uncertain)
    end

    test "threshold values are floats" do
      thresholds = NoiseFilter.weight_thresholds()

      assert is_float(thresholds.definitely_noise)
      assert is_float(thresholds.likely_noise)
      assert is_float(thresholds.uncertain)
    end

    test "thresholds are ordered: definitely_noise < likely_noise < uncertain < 1.0" do
      t = NoiseFilter.weight_thresholds()

      assert t.definitely_noise < t.likely_noise
      assert t.likely_noise < t.uncertain
      assert t.uncertain < 1.0
    end

    test "defaults match documented values" do
      # Documented defaults: 0.15, 0.35, 0.65
      t = NoiseFilter.weight_thresholds()

      assert_in_delta t.definitely_noise, 0.15, 0.10
      assert_in_delta t.likely_noise, 0.35, 0.10
      assert_in_delta t.uncertain, 0.65, 0.10
    end
  end

  # ---------------------------------------------------------------------------
  # calibrate_weights/2
  # ---------------------------------------------------------------------------

  describe "calibrate_weights/2" do
    test "returns current thresholds unchanged when total < 50" do
      stats = %{"0.0-0.2": 10, "0.2-0.5": 5, "0.5-0.8": 3, "0.8-1.0": 2}
      current = NoiseFilter.weight_thresholds()
      result = NoiseFilter.calibrate_weights(stats)

      assert result == current
    end

    test "returns a map with the three threshold keys" do
      stats = %{"0.0-0.2": 100, "0.2-0.5": 20, "0.5-0.8": 10, "0.8-1.0": 5}
      result = NoiseFilter.calibrate_weights(stats)

      assert Map.has_key?(result, :definitely_noise)
      assert Map.has_key?(result, :likely_noise)
      assert Map.has_key?(result, :uncertain)
    end

    test "tightens definitely_noise when low bucket > 70% of total" do
      # High low_ratio → threshold should increase (tighten)
      current = NoiseFilter.weight_thresholds()

      stats = %{"0.0-0.2": 800, "0.2-0.5": 100, "0.5-0.8": 50, "0.8-1.0": 50}
      result = NoiseFilter.calibrate_weights(stats)

      assert result.definitely_noise >= current.definitely_noise
    end

    test "loosens definitely_noise when low bucket < 30% of total" do
      # Low low_ratio → threshold should decrease (loosen)
      current = NoiseFilter.weight_thresholds()

      stats = %{"0.0-0.2": 10, "0.2-0.5": 400, "0.5-0.8": 400, "0.8-1.0": 190}
      result = NoiseFilter.calibrate_weights(stats)

      assert result.definitely_noise <= current.definitely_noise
    end

    test "calibrated definitely_noise stays within configured bounds" do
      stats = %{"0.0-0.2": 900, "0.2-0.5": 50, "0.5-0.8": 30, "0.8-1.0": 20}
      result = NoiseFilter.calibrate_weights(stats)

      assert result.definitely_noise >= 0.10
      assert result.definitely_noise <= 0.25
    end
  end

  # ---------------------------------------------------------------------------
  # filter_and_reply/3
  # ---------------------------------------------------------------------------

  describe "filter_and_reply/3" do
    test "returns false and does not call reply_fn for a passing message" do
      called = :atomics.new(1, [])

      result =
        NoiseFilter.filter_and_reply(
          "Explain the OTP supervision strategy for fault tolerance",
          nil,
          fn _text -> :atomics.add(called, 1, 1) end
        )

      assert result == false
      assert :atomics.get(called, 1) == 0
    end

    test "returns true and calls reply_fn for a filtered message" do
      {:ok, received} = Agent.start_link(fn -> nil end)

      result =
        NoiseFilter.filter_and_reply("ok", nil, fn text ->
          Agent.update(received, fn _ -> text end)
        end)

      assert result == true
      reply = Agent.get(received, & &1)
      assert is_binary(reply)
      Agent.stop(received)
    end

    test "returns true and calls reply_fn with clarification prompt" do
      {:ok, received} = Agent.start_link(fn -> nil end)

      result =
        NoiseFilter.filter_and_reply("maybe", 0.50, fn text ->
          Agent.update(received, fn _ -> text end)
        end)

      assert result == true
      reply = Agent.get(received, & &1)
      assert is_binary(reply)
      Agent.stop(received)
    end

    test "returns true for empty string without calling reply_fn" do
      called = :atomics.new(1, [])

      result =
        NoiseFilter.filter_and_reply("", nil, fn _text ->
          :atomics.add(called, 1, 1)
        end)

      assert result == true
      assert :atomics.get(called, 1) == 0
    end
  end
end
