defmodule OptimalSystemAgent.Agent.Loop.ReasoningWatchdogTest do
  @moduledoc """
  Unit tests for the in-stream degeneration detector. See the module's
  moduledoc for the four rules and why the defaults are conservative.

  Each test configures `:reasoning_watchdog` explicitly rather than relying
  on the shipped defaults, so this suite is insulated from future default
  tuning — it tests the RULES, not today's numbers.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReasoningWatchdog, as: Watchdog

  @key :reasoning_watchdog

  setup do
    original = Application.get_env(:optimal_system_agent, @key)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:optimal_system_agent, @key)
  defp restore(value), do: Application.put_env(:optimal_system_agent, @key, value)

  defp configure(opts), do: Application.put_env(:optimal_system_agent, @key, opts)

  # Feed a list of deltas on `channel` into a fresh watchdog, one `observe/3`
  # call per delta, stopping at the first trip. Returns `{:trip, info}` or
  # `{:ok, watchdog}`.
  defp run(channel, deltas) do
    Enum.reduce_while(deltas, {:ok, Watchdog.new()}, fn delta, {:ok, w} ->
      case Watchdog.observe(w, channel, delta) do
        {:ok, w} -> {:cont, {:ok, w}}
        {:trip, info, w} -> {:halt, {:trip, info, w}}
      end
    end)
  end

  describe "rule (a): repeated short phrase" do
    setup do
      configure(
        check_every_chars: 8,
        repeated_phrase_threshold: 4,
        window_chars: 2_000
      )

      :ok
    end

    test "a short line repeated many times trips, with the phrase and count in the cause" do
      deltas = List.duplicate("OK. ", 12)

      assert {:trip, info, _w} = run(:reasoning, deltas)
      assert info.rule == :repeated_phrase
      assert info.channel == :reasoning
      assert info.cause =~ "OK."
      assert info.cause =~ ~r/x\d+/
    end

    test "the SAME repetition on the plain-text channel also trips" do
      deltas = List.duplicate("Producing. ", 10)

      assert {:trip, info, _w} = run(:text, deltas)
      assert info.rule == :repeated_phrase
      assert info.channel == :text
    end

    test "a few repeats (below threshold) never trip" do
      deltas = List.duplicate("OK. ", 3)
      assert {:ok, _w} = run(:reasoning, deltas)
    end
  end

  describe "rule (b): n-gram repetition" do
    setup do
      configure(
        check_every_chars: 10,
        ngram_n: 3,
        ngram_min_total: 5,
        ngram_repetition_ratio: 0.5,
        # High threshold so rule (a) never fires first and masks rule (b).
        repeated_phrase_threshold: 1_000
      )

      :ok
    end

    test "a recurring multi-word span (not a single short line) trips" do
      # No sentence punctuation, so rule (a)'s line/phrase split never
      # produces a short repeated chunk — only the n-gram check can catch
      # this shape.
      deltas = List.duplicate("check the file again and ", 8)

      assert {:trip, info, _w} = run(:reasoning, deltas)
      assert info.rule == :ngram_repetition
    end
  end

  describe "rule (c): collapsing lexical diversity" do
    setup do
      configure(
        check_every_chars: 10,
        lexical_window_tokens: 20,
        lexical_diversity_floor: 0.3,
        repeated_phrase_threshold: 1_000,
        ngram_repetition_ratio: 1.1
      )

      :ok
    end

    test "cycling a small vocabulary trips even without an exact repeated line" do
      # Reorders a tiny 4-word pool so no fixed short phrase or long n-gram
      # repeats verbatim, but the unique/total token ratio still collapses.
      words = ["alpha", "beta", "gamma", "delta"]
      deltas = for i <- 1..24, do: Enum.at(words, rem(i, 4)) <> " "

      assert {:trip, info, _w} = run(:reasoning, deltas)
      assert info.rule == :lexical_collapse
    end
  end

  describe "rule (d): stalled (time/char backstop, no tool call or answer)" do
    setup do
      configure(
        max_reasoning_ms: 50,
        max_reasoning_chars: 10_000,
        check_every_chars: 4,
        repeated_phrase_threshold: 1_000,
        ngram_repetition_ratio: 1.1,
        lexical_diversity_floor: -1.0
      )

      :ok
    end

    test "reasoning that runs past the time bound with no tool call or answer trips" do
      w = Watchdog.new()
      Process.sleep(60)

      assert {:trip, info, _w} = Watchdog.observe(w, :reasoning, "still thinking... ")
      assert info.rule == :stalled
      assert info.cause =~ "no tool call or answer"
    end

    test "a tool call streaming before the bound clears the backstop" do
      configure(
        max_reasoning_ms: 30,
        check_every_chars: 4,
        repeated_phrase_threshold: 1_000,
        ngram_repetition_ratio: 1.1,
        lexical_diversity_floor: -1.0
      )

      w = Watchdog.new() |> Watchdog.note_tool_call()
      Process.sleep(50)

      assert {:ok, _w} = Watchdog.observe(w, :reasoning, "still thinking... ")
    end

    test "any answer text arriving before the bound clears the backstop too" do
      configure(
        max_reasoning_ms: 30,
        check_every_chars: 4,
        repeated_phrase_threshold: 1_000,
        ngram_repetition_ratio: 1.1,
        lexical_diversity_floor: -1.0
      )

      {:ok, w} = Watchdog.observe(Watchdog.new(), :text, "Here is the answer.")
      Process.sleep(50)

      assert {:ok, _w} = Watchdog.observe(w, :reasoning, "still thinking... ")
    end

    test "the char bound also trips with no tool call or answer" do
      configure(
        max_reasoning_ms: 3_600_000,
        max_reasoning_chars: 20,
        check_every_chars: 4,
        repeated_phrase_threshold: 1_000,
        ngram_repetition_ratio: 1.1,
        lexical_diversity_floor: -1.0
      )

      deltas = List.duplicate("xyzqw ", 10)
      assert {:trip, info, _w} = run(:reasoning, deltas)
      assert info.rule == :stalled
      assert info.cause =~ "characters"
    end
  end

  describe "a long, varied, PRODUCTIVE reasoning stream never trips (default config)" do
    test "realistic multi-paragraph reasoning, streamed in small chunks, is clean" do
      # Shipped defaults, not a test-tuned config — this is the fixture the
      # defaults are measured against.
      paragraph =
        "Let me look at how the authentication middleware validates the bearer " <>
          "token before deciding how to fix the expiry check. The current " <>
          "implementation reads the Authorization header, splits on the first " <>
          "space, and decodes the remainder as a JWT without verifying the " <>
          "issuer claim, which means a token signed by a different tenant would " <>
          "still pass. I should check whether the JWKS cache is refreshed on a " <>
          "background timer or fetched synchronously on each request, since " <>
          "that changes whether a key-rotation window can cause a false " <>
          "rejection during the fix. Looking at the surrounding module, the " <>
          "cache appears to be a GenServer that refreshes every ten minutes, " <>
          "with a fallback to a synchronous fetch when the cache is empty, so " <>
          "the rotation window is bounded. Given that, the safest fix is to add " <>
          "an explicit issuer check right after signature verification, return " <>
          "a structured 401 with a reason code when it fails, and add a " <>
          "regression test that signs a token with a different issuer and " <>
          "asserts the request is rejected. I will also check whether any " <>
          "other call site assumes the old permissive behavior before changing " <>
          "it, since a silent behavior change here could break an internal " <>
          "service that has not rotated its issuer configuration yet."

      # A second, DIFFERENT paragraph — a longer session that is still
      # genuinely non-repeating (concatenating the SAME text twice would be
      # testing something else: a model that repeats a whole block verbatim
      # legitimately IS the degenerate shape rule (b)/(c) exist to catch).
      paragraph2 =
        "Now that the issuer check is in place, I want to make sure the " <>
          "existing test suite for the login flow still passes, since that " <>
          "flow shares the same middleware stack. Running the suite locally " <>
          "surfaced one failure in a fixture that hard-codes an old token " <>
          "without an issuer claim at all, which the new check correctly " <>
          "rejects — so the fixture itself needs updating, not the " <>
          "middleware. I will regenerate that fixture from the same helper " <>
          "the new regression test uses, rerun the suite, and then look at " <>
          "whether the error message returned to the client is specific " <>
          "enough to debug without leaking which claim failed to an " <>
          "unauthenticated caller, since that is a separate information " <>
          "disclosure concern worth getting right in the same change."

      # Stream both in small, realistic chunks (a handful of words per delta).
      deltas =
        (paragraph <> " " <> paragraph2)
        |> String.split(" ")
        |> Enum.chunk_every(4)
        |> Enum.map(&(Enum.join(&1, " ") <> " "))

      result =
        Enum.reduce_while(deltas, {:ok, Watchdog.new()}, fn delta, {:ok, w} ->
          case Watchdog.observe(w, :reasoning, delta) do
            {:ok, w} -> {:cont, {:ok, w}}
            {:trip, info, w} -> {:halt, {:trip, info, w}}
          end
        end)

      assert {:ok, _w} = result
    end
  end

  describe "cheap and bounded" do
    test "the reasoning buffer never grows past the configured window" do
      configure(window_chars: 100, check_every_chars: 1_000_000)

      {:ok, w} =
        Enum.reduce(1..50, {:ok, Watchdog.new()}, fn _i, {:ok, w} ->
          Watchdog.observe(w, :reasoning, String.duplicate("a", 20))
        end)

      assert String.length(w.reasoning_buf) <= 100
    end
  end
end
