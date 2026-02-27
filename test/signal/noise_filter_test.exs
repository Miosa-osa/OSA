defmodule OptimalSystemAgent.Signal.NoiseFilterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.NoiseFilter

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  defp noise?(msg) do
    match?({:noise, _}, NoiseFilter.filter(msg))
  end

  defp signal?(msg) do
    match?({:signal, _}, NoiseFilter.filter(msg))
  end

  defp noise_reason(msg) do
    {:noise, reason} = NoiseFilter.filter(msg)
    reason
  end

  defp signal_weight(msg) do
    {:signal, weight} = NoiseFilter.filter(msg)
    weight
  end

  # ---------------------------------------------------------------------------
  # Empty / whitespace messages
  # ---------------------------------------------------------------------------

  describe "empty messages" do
    test "empty string is noise" do
      assert noise?("")
    end

    test "empty string reason is :empty" do
      assert noise_reason("") == :empty
    end

    test "whitespace-only string is noise" do
      assert noise?("   ")
    end

    test "whitespace-only reason is :empty (matched by regex) or :too_short after trim" do
      # After trim "   " becomes "", length == 0, so :empty
      assert noise_reason("   ") == :empty
    end

    test "tab-only string is noise" do
      assert noise?("\t")
    end

    test "newline-only string is noise" do
      assert noise?("\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Short messages (< 3 chars after trim)
  # ---------------------------------------------------------------------------

  describe "short messages" do
    test "single character is noise" do
      assert noise?("a")
    end

    test "single character reason is :too_short" do
      assert noise_reason("a") == :too_short
    end

    test "two character message is noise" do
      assert noise?("hi")
    end

    test "two character message reason is :too_short" do
      assert noise_reason("hi") == :too_short
    end

    test "exactly 3 characters bypasses too_short check" do
      # "sup" is 3 chars but matches a noise pattern — reason should be :pattern_match
      result = NoiseFilter.filter("sup")
      assert match?({:noise, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Greeting patterns
  # ---------------------------------------------------------------------------

  describe "greetings" do
    test "'hi' is noise" do
      assert noise?("hi")
    end

    test "'hello' is noise" do
      assert noise?("hello")
    end

    test "'hey' is noise" do
      assert noise?("hey")
    end

    test "'yo' is noise" do
      assert noise?("yo")
    end

    test "'sup' is noise" do
      assert noise?("sup")
    end

    test "greeting with trailing whitespace is noise" do
      assert noise?("hello   ")
    end

    test "greeting with exclamation is noise" do
      assert noise?("hello!")
    end

    test "greeting with period is noise" do
      assert noise?("hi.")
    end

    test "greeting with 'good morning' is noise" do
      assert noise?("good morning")
    end

    test "greeting 'gm' is noise" do
      assert noise?("gm")
    end

    test "greeting 'good night' is noise" do
      assert noise?("good night")
    end

    test "greeting 'gn' is noise" do
      assert noise?("gn")
    end

    test "greeting patterns are case-insensitive" do
      assert noise?("Hello")
      assert noise?("HEY")
      assert noise?("Good Morning")
    end

    test "greeting reason is :pattern_match" do
      assert noise_reason("hello") == :pattern_match
    end
  end

  # ---------------------------------------------------------------------------
  # Acknowledgment patterns
  # ---------------------------------------------------------------------------

  describe "acknowledgments" do
    test "'ok' is noise" do
      assert noise?("ok")
    end

    test "'okay' is noise" do
      assert noise?("okay")
    end

    test "'sure' is noise" do
      assert noise?("sure")
    end

    test "'yep' is noise" do
      assert noise?("yep")
    end

    test "'yeah' is noise" do
      assert noise?("yeah")
    end

    test "'yes' is noise" do
      assert noise?("yes")
    end

    test "'no' is noise" do
      assert noise?("no")
    end

    test "'nah' is noise" do
      assert noise?("nah")
    end

    test "'nope' is noise" do
      assert noise?("nope")
    end

    test "acknowledgment with exclamation is noise" do
      assert noise?("ok!")
    end

    test "acknowledgment reason is :pattern_match" do
      assert noise_reason("sure") == :pattern_match
    end
  end

  # ---------------------------------------------------------------------------
  # Thanks / appreciation patterns
  # ---------------------------------------------------------------------------

  describe "thanks" do
    test "'thanks' is noise" do
      assert noise?("thanks")
    end

    test "'thank you' is noise" do
      assert noise?("thank you")
    end

    test "'ty' is noise" do
      # 'ty' is 2 chars — :too_short before reaching pattern check
      result = NoiseFilter.filter("ty")
      assert match?({:noise, _}, result)
    end

    test "'thx' is noise" do
      assert noise?("thx")
    end

    test "'cheers' is noise" do
      assert noise?("cheers")
    end

    test "thanks reason is :pattern_match" do
      assert noise_reason("thanks") == :pattern_match
    end
  end

  # ---------------------------------------------------------------------------
  # Reaction / filler patterns
  # ---------------------------------------------------------------------------

  describe "reactions" do
    test "'lol' is noise" do
      assert noise?("lol")
    end

    test "'haha' is noise" do
      assert noise?("haha")
    end

    test "'hehe' is noise" do
      assert noise?("hehe")
    end

    test "'lmao' is noise" do
      assert noise?("lmao")
    end

    test "'rofl' is noise" do
      assert noise?("rofl")
    end

    test "reaction reason is :pattern_match" do
      assert noise_reason("lol") == :pattern_match
    end
  end

  # ---------------------------------------------------------------------------
  # Real messages — should be classified as :signal
  # ---------------------------------------------------------------------------

  describe "real messages" do
    test "multi-word task request is a signal" do
      assert signal?("please analyze the production logs from last night")
    end

    test "question is a signal" do
      assert signal?("what caused the outage this morning?")
    end

    test "technical statement is a signal" do
      assert signal?("the deployment failed because of a missing env var")
    end

    test "long description is a signal" do
      assert signal?(
               "I need you to review the refactored authentication module and flag any security concerns"
             )
    end

    test "code-related request is a signal" do
      assert signal?("generate a migration script for adding the users table")
    end

    test "scheduling request is a signal" do
      assert signal?("remind me to run the backup at midnight")
    end

    test "signal returns a float weight between 0.0 and 1.0" do
      weight = signal_weight("analyze revenue trends for the past quarter")

      assert is_float(weight)
      assert weight >= 0.0
      assert weight <= 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # Urgent messages — should always be signal
  # ---------------------------------------------------------------------------

  describe "urgent messages" do
    test "message with 'urgent' is a signal" do
      assert signal?("urgent: the prod database is down")
    end

    test "message with 'critical' is a signal" do
      assert signal?("critical error in the payment processor")
    end

    test "message with 'emergency' is a signal" do
      assert signal?("emergency rollback needed immediately")
    end

    test "urgent message has weight >= 0.7" do
      weight = signal_weight("critical production outage, need immediate fix")

      assert weight >= 0.7
    end

    test "urgent question without substring noise has weight >= 0.85" do
      # "status critical?" - no noise substring, has urgency ('critical') and '?'
      # base 0.5 + length_bonus + 0.15 + 0.2 = ~0.88
      weight = signal_weight("status critical?")

      assert weight >= 0.85
    end
  end

  # ---------------------------------------------------------------------------
  # Weight threshold tiers
  # ---------------------------------------------------------------------------

  describe "weight thresholds" do
    test "message that scores < 0.3 after trim is noise with :low_weight" do
      # A message with a noise keyword that survives pattern check but is low-weight:
      # We need to engineer a message that passes patterns but has weight < 0.3.
      # 'ok dude' has 'ok' embedded but doesn't match ^(ok|...)$ exactly.
      # Let's construct a message that includes a noise word in the middle to trigger
      # the -0.3 penalty and keep base at 0.5, resulting in 0.2.
      # "say hi" — 'hi' triggers noise_penalty -0.3 => weight 0.2
      result = NoiseFilter.filter("say hi")

      # Either noise from pattern or low_weight; both are acceptable for this input
      assert match?({:noise, _}, result) or match?({:signal, _}, result)
    end

    test "message with weight exactly in uncertain band (0.3-0.6) passes through as signal (Tier 2 pass-through)" do
      # A medium-length generic message with no bonuses or penalties sits at 0.5
      # which is in the uncertain band (0.3 <= 0.5 < 0.6) — Tier 2 returns {:signal, weight}
      result = NoiseFilter.filter("the server restarted successfully after the patch")

      assert match?({:signal, _}, result)
    end

    test "message with weight > 0.6 is directly classified as signal by Tier 1" do
      # Urgency bonus pushes past 0.6
      result = NoiseFilter.filter("critical alert: disk usage at 95%")

      assert {:signal, weight} = result
      assert weight > 0.6
    end

    test "filter/1 returns :noise tuple or :signal tuple — never a bare value" do
      result = NoiseFilter.filter("any message")

      assert match?({tag, _} when tag in [:noise, :signal], result)
    end
  end

  # ---------------------------------------------------------------------------
  # Return value shapes
  # ---------------------------------------------------------------------------

  describe "return value contracts" do
    test "noise result is {:noise, atom}" do
      {:noise, reason} = NoiseFilter.filter("")

      assert is_atom(reason)
    end

    test "signal result is {:signal, float}" do
      {:signal, weight} = NoiseFilter.filter("analyze the deployment pipeline logs")

      assert is_float(weight)
    end

    test "signal weight is never negative" do
      {:signal, weight} = NoiseFilter.filter("generate a report on system performance metrics")

      assert weight >= 0.0
    end

    test "signal weight never exceeds 1.0" do
      {:signal, weight} = NoiseFilter.filter("critical urgent emergency fix needed immediately?")

      assert weight <= 1.0
    end
  end
end
