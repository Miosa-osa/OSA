defmodule OptimalSystemAgent.Providers.HistorySanitizerTest do
  @moduledoc """
  Reproduces the self-heal gap from the audit: a corrupted transcript (an
  orphan tool_result, an orphan tool_use, or a degenerate empty-content
  message) reaches the provider unchanged and the resulting 400 repeats on
  EVERY subsequent turn, because nothing ever repairs the shape that
  triggered it.

  `HistorySanitizer.sanitize/2` is the fix: run before every provider
  request, it drops orphan tool_results, fills orphan tool_uses, and
  prunes/merges degenerate content — all without reordering messages or
  touching `:thinking_blocks`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.HistorySanitizer, as: Sanitizer

  describe "drop_orphaned_tool_results/1 — a tool_result with no matching tool_use" do
    test "is dropped (the 'unexpected tool_use_id' 400 trigger)" do
      messages = [
        %{role: "user", content: "hi"},
        %{role: "tool", tool_call_id: "orphan_1", content: "stray result"},
        %{role: "assistant", content: "hello"}
      ]

      {repaired, changed?} = Sanitizer.drop_orphaned_tool_results(messages)

      assert changed?
      refute Enum.any?(repaired, &(Map.get(&1, :role) == "tool"))
      # Everything else survives, in the same order.
      assert repaired == [
               %{role: "user", content: "hi"},
               %{role: "assistant", content: "hello"}
             ]
    end

    test "a correctly paired tool_result is left alone" do
      tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}

      messages = [
        %{role: "user", content: "run it"},
        %{role: "assistant", content: "", tool_calls: [tc]},
        %{role: "tool", tool_call_id: "tc_1", content: "ok"}
      ]

      {repaired, changed?} = Sanitizer.drop_orphaned_tool_results(messages)

      refute changed?
      assert repaired == messages
    end

    test "a no-op on clean history reports changed? == false" do
      messages = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
      assert Sanitizer.drop_orphaned_tool_results(messages) == {messages, false}
    end
  end

  describe "fill_missing_tool_results/2 — a tool_use with no result" do
    test "gets a synthetic result inserted immediately after its owner, not at the tail" do
      tc = %{id: "tc_orphan", name: "shell_execute", arguments: %{}}

      messages = [
        %{role: "user", content: "run it"},
        %{role: "assistant", content: "on it", tool_calls: [tc]},
        # A message AFTER the orphaned tool_use — a tail append would land the
        # synthetic result here instead, which is the shape every strict
        # provider (Anthropic, Gemini) rejects.
        %{role: "assistant", content: "…more text"}
      ]

      {repaired, changed?} = Sanitizer.fill_missing_tool_results(messages, "placeholder text")

      assert changed?

      assert Enum.at(repaired, 2) == %{
               role: "tool",
               tool_call_id: "tc_orphan",
               content: "placeholder text"
             }

      # Placement: directly after its owning assistant message.
      assert Enum.at(repaired, 1).tool_calls == [tc]
      assert length(repaired) == 4
    end

    test "an already-answered tool_use is not given a second result" do
      tc = %{id: "tc_done", name: "read_file", arguments: %{}}

      messages = [
        %{role: "assistant", content: "", tool_calls: [tc]},
        %{role: "tool", tool_call_id: "tc_done", content: "contents"}
      ]

      assert Sanitizer.fill_missing_tool_results(messages, "placeholder") == {messages, false}
    end

    test "accepts a 1-arity placeholder function keyed by tool_call_id" do
      tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}
      messages = [%{role: "assistant", content: "", tool_calls: [tc]}]

      {repaired, true} =
        Sanitizer.fill_missing_tool_results(messages, fn id -> "no result for #{id}" end)

      assert Enum.at(repaired, 1).content == "no result for tc_1"
    end

    test "tolerates string-keyed messages (checkpoint restore shape)" do
      messages = [
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [%{"id" => "tc_str", "name" => "shell_execute", "arguments" => %{}}]
        }
      ]

      {repaired, true} = Sanitizer.fill_missing_tool_results(messages, "gap")
      assert Enum.at(repaired, 1) == %{role: "tool", tool_call_id: "tc_str", content: "gap"}
    end
  end

  describe "normalize_empty_text/1 — degenerate content" do
    test "drops a message whose content is an empty string" do
      messages = [
        %{role: "user", content: "hi"},
        %{role: "assistant", content: ""},
        %{role: "user", content: "still there?"}
      ]

      {repaired, changed?} = Sanitizer.normalize_empty_text(messages)

      assert changed?

      assert repaired == [
               %{role: "user", content: "hi"},
               %{role: "user", content: "still there?"}
             ]
    end

    test "drops a message whose content-block list is only blank text (the empty-text-block 400)" do
      messages = [
        %{role: "user", content: "hi"},
        %{role: "assistant", content: [%{"type" => "text", "text" => ""}]}
      ]

      {repaired, true} = Sanitizer.normalize_empty_text(messages)
      assert repaired == [%{role: "user", content: "hi"}]
    end

    test "prunes a blank block but keeps the message when another block has real content" do
      messages = [
        %{
          role: "user",
          content: [
            %{"type" => "text", "text" => ""},
            %{"type" => "image", "source" => %{"type" => "base64", "data" => "abc"}}
          ]
        }
      ]

      {[repaired], true} = Sanitizer.normalize_empty_text(messages)

      assert repaired.content == [
               %{"type" => "image", "source" => %{"type" => "base64", "data" => "abc"}}
             ]
    end

    test "merges adjacent plain-text blocks left behind after pruning" do
      messages = [
        %{
          role: "assistant",
          content: [
            %{"type" => "text", "text" => "hello "},
            %{"type" => "text", "text" => ""},
            %{"type" => "text", "text" => "world"}
          ]
        }
      ]

      {[repaired], true} = Sanitizer.normalize_empty_text(messages)
      assert repaired.content == [%{"type" => "text", "text" => "hello world"}]
    end

    test "never merges across a block carrying its own cache_control breakpoint" do
      messages = [
        %{
          role: "system",
          content: [
            %{
              "type" => "text",
              "text" => "static base",
              "cache_control" => %{"type" => "ephemeral"}
            },
            %{"type" => "text", "text" => "volatile tail"}
          ]
        }
      ]

      assert Sanitizer.normalize_empty_text(messages) == {messages, false}
    end

    test "a tool result's content is legitimately empty (e.g. a silent command) and is untouched" do
      messages = [%{role: "tool", tool_call_id: "tc_1", content: ""}]
      assert Sanitizer.normalize_empty_text(messages) == {messages, false}
    end

    test "a message carrying tool_calls with blank text is untouched — the tool_use IS its content" do
      tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}
      messages = [%{role: "assistant", content: "", tool_calls: [tc]}]
      assert Sanitizer.normalize_empty_text(messages) == {messages, false}
    end

    test "a message carrying signed :thinking_blocks is left completely alone, even with empty content" do
      messages = [
        %{
          role: "assistant",
          content: "",
          thinking_blocks: [%{type: "thinking", thinking: "reasoning…", signature: "sig123"}]
        }
      ]

      # Must not drop, must not touch `:thinking_blocks` — Anthropic requires
      # a signed thinking block to be replayed byte-for-byte.
      assert Sanitizer.normalize_empty_text(messages) == {messages, false}
    end
  end

  describe "sanitize/2 — the full pipeline, as run before every provider request" do
    test "repairs all three corruption shapes in one pass, without reordering anything" do
      tc = %{id: "tc_missing_result", name: "shell_execute", arguments: %{}}

      messages = [
        %{role: "user", content: "do three things"},
        # 1. orphan tool_result (no matching tool_use anywhere)
        %{role: "tool", tool_call_id: "ghost", content: "stray"},
        # 2. orphan tool_use (no result at all)
        %{role: "assistant", content: "working", tool_calls: [tc]},
        # 3. degenerate empty-text message
        %{role: "assistant", content: [%{"type" => "text", "text" => ""}]},
        %{role: "user", content: "keep going"}
      ]

      {repaired, changed?} = Sanitizer.sanitize(messages)

      assert changed?
      refute Enum.any?(repaired, &(Map.get(&1, :tool_call_id) == "ghost"))
      assert Enum.any?(repaired, &(Map.get(&1, :tool_call_id) == "tc_missing_result"))
      refute Enum.any?(repaired, &(Map.get(&1, :content) == [%{"type" => "text", "text" => ""}]))

      # Original relative order preserved for every surviving message.
      assert Enum.at(repaired, 0) == %{role: "user", content: "do three things"}
      assert List.last(repaired) == %{role: "user", content: "keep going"}
    end

    test "a clean history round-trips byte-for-byte with changed? == false" do
      messages = [
        %{role: "user", content: "hi"},
        %{role: "assistant", content: "hello there"}
      ]

      assert Sanitizer.sanitize(messages) == {messages, false}
    end

    test "honors a custom :orphan_result_text for the fill pass" do
      tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}
      messages = [%{role: "assistant", content: "", tool_calls: [tc]}]

      {repaired, true} = Sanitizer.sanitize(messages, orphan_result_text: "custom note")
      assert Enum.at(repaired, 1).content == "custom note"
    end

    test "is idempotent — sanitizing already-sanitized history changes nothing" do
      tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}

      messages = [
        %{role: "tool", tool_call_id: "ghost", content: "stray"},
        %{role: "assistant", content: "", tool_calls: [tc]}
      ]

      {once, true} = Sanitizer.sanitize(messages)
      assert Sanitizer.sanitize(once) == {once, false}
    end
  end
end
