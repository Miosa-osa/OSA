defmodule OptimalSystemAgent.Providers.RecordModelSpeedTest do
  # async: false — shares global state (persistent_term + the SQLite
  # `model_speed` table) with ModelSpeedTest via
  # OptimalSystemAgent.Providers.ModelSpeed, and this file resets it between
  # tests. Kept in its own async:false file (rather than folded into the
  # async:true OpenAICompatTest) so it never races that shared state against
  # anything else.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.ModelSpeed
  alias OptimalSystemAgent.Providers.OpenAICompat

  setup do
    ModelSpeed.reset()
    on_exit(fn -> ModelSpeed.reset() end)
  end

  defp sse(payload), do: "data: #{Jason.encode!(payload)}\n\n"

  # ---------------------------------------------------------------------------
  # debug_gen_window/1 — proves `process_delta/3` stamps the visible-generation
  # window (`stamp_visible_gen/2`) for real content and NEVER for invisible
  # reasoning or suppressed tool-call markup.
  # ---------------------------------------------------------------------------

  describe "debug_gen_window/1 — what actually gets stamped" do
    test "a visible content chunk stamps both timestamps" do
      chunks = [sse(%{"choices" => [%{"delta" => %{"content" => "Hello there"}}]})]

      assert {first, last} = OpenAICompat.debug_gen_window(chunks)
      assert is_integer(first)
      assert is_integer(last)
      assert last >= first
    end

    test "a reasoning-only stream (no visible content at all) leaves both nil" do
      chunks = [
        sse(%{"choices" => [%{"delta" => %{"reasoning" => "thinking very hard about this"}}]}),
        sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})
      ]

      assert OpenAICompat.debug_gen_window(chunks) == {nil, nil}
    end

    test "content suppressed as XML tool-call markup leaves both nil" do
      chunks = [
        sse(%{
          "choices" => [
            %{"delta" => %{"content" => ~s|<function name="x" parameters={}></function>|}}
          ]
        })
      ]

      assert OpenAICompat.debug_gen_window(chunks) == {nil, nil}
    end

    test "reasoning followed by a real visible answer stamps only the visible part" do
      chunks = [
        sse(%{"choices" => [%{"delta" => %{"reasoning" => "let me think..."}}]}),
        sse(%{"choices" => [%{"delta" => %{"content" => "The answer is 42."}}]})
      ]

      assert {first, last} = OpenAICompat.debug_gen_window(chunks)
      assert is_integer(first)
      assert is_integer(last)
    end

    test "an empty stream leaves both nil" do
      assert OpenAICompat.debug_gen_window(["data: [DONE]\n\n"]) == {nil, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # record_model_speed/4 — the guarded metric recorder. Every guard is tested
  # independently so a future edit that loosens one is caught immediately.
  # ---------------------------------------------------------------------------

  describe "record_model_speed/4" do
    test "a normal visible-content turn records a plausible tok/s" do
      acc = %{gen_first_ts: 1_000, gen_last_ts: 2_000}
      usage = %{output_tokens: 100, reasoning_tokens: 0}

      assert OpenAICompat.record_model_speed(acc, usage, "test-model-a", provider: :surplus) ==
               :ok

      # 100 tokens over a 1000ms (1s) window == 100 tok/s.
      assert ModelSpeed.get(:surplus, "test-model-a") == 100.0
    end

    test "a turn that emitted zero visible content (no gen window) records nothing" do
      acc = %{gen_first_ts: nil, gen_last_ts: nil}
      usage = %{output_tokens: 600, reasoning_tokens: 0}

      OpenAICompat.record_model_speed(acc, usage, "test-model-b", provider: :surplus)

      assert ModelSpeed.get(:surplus, "test-model-b") == nil
    end

    test "a zero-duration window (single chunk) records nothing rather than dividing by ~0" do
      acc = %{gen_first_ts: 5_000, gen_last_ts: 5_000}
      usage = %{output_tokens: 10, reasoning_tokens: 0}

      OpenAICompat.record_model_speed(acc, usage, "test-model-c", provider: :surplus)

      assert ModelSpeed.get(:surplus, "test-model-c") == nil
    end

    test "usage that was never reported by the server (estimate fallback) records nothing" do
      acc = %{gen_first_ts: 1_000, gen_last_ts: 2_000}
      usage = %{output_tokens: 100, reasoning_tokens: 0, estimated: true}

      OpenAICompat.record_model_speed(acc, usage, "test-model-d", provider: :surplus)

      assert ModelSpeed.get(:surplus, "test-model-d") == nil
    end

    test "a turn whose completion was entirely reasoning tokens records nothing" do
      # completion_tokens == reasoning_tokens: no ACTUAL visible tokens, even
      # though a gen window happens to be present.
      acc = %{gen_first_ts: 1_000, gen_last_ts: 2_000}
      usage = %{output_tokens: 600, reasoning_tokens: 600}

      OpenAICompat.record_model_speed(acc, usage, "test-model-e", provider: :surplus)

      assert ModelSpeed.get(:surplus, "test-model-e") == nil
    end

    test "reasoning tokens are subtracted from the visible-tok/s estimate, not double-counted" do
      # 500 total completion tokens, 400 of them invisible reasoning => only
      # 100 visible tokens over the 1s window => 100 tok/s, NOT 500 tok/s.
      acc = %{gen_first_ts: 1_000, gen_last_ts: 2_000}
      usage = %{output_tokens: 500, reasoning_tokens: 400}

      OpenAICompat.record_model_speed(acc, usage, "test-model-f", provider: :surplus)

      assert ModelSpeed.get(:surplus, "test-model-f") == 100.0
    end

    test "defaults to :openai_compatible when opts carries no :provider" do
      acc = %{gen_first_ts: 1_000, gen_last_ts: 2_000}
      usage = %{output_tokens: 100, reasoning_tokens: 0}

      OpenAICompat.record_model_speed(acc, usage, "test-model-g", [])

      assert ModelSpeed.get(:openai_compatible, "test-model-g") == 100.0
    end

    test "never raises even when acc/usage are missing expected keys" do
      assert OpenAICompat.record_model_speed(%{}, %{}, "test-model-h", provider: :surplus) == :ok
      assert ModelSpeed.get(:surplus, "test-model-h") == nil
    end
  end
end
