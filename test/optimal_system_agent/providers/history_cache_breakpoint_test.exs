defmodule OptimalSystemAgent.Providers.HistoryCacheBreakpointTest do
  @moduledoc """
  Where the cache breakpoints sit relative to message history — the fact that
  decides whether rewriting a stale tool result in place is free or ruinous.

  `docs/design/tool-output-pruning.md` concludes that in-place pruning of old
  tool output is safe on the native Anthropic route and a large net loss on the
  OpenRouter route. That conclusion is not a judgement call; it follows entirely
  from ONE structural fact per route:

    * **Native Anthropic** places `cache_control` only on system blocks
      (`Agent.Context.build_system_message/5`) and on the last tool definition
      (`Anthropic.mark_tools_cache_boundary/1`). Both segments sit BEFORE all
      history, so the cached prefix ends where history begins and no rewrite of
      a message can invalidate it.

    * **OpenRouter → Anthropic** (`{:compat, _}`) additionally rolls a
      breakpoint onto the LAST HISTORY MESSAGE (`PromptCache.do_restructure/1`).
      The cached segment therefore spans the whole history, and rewriting any
      earlier message means the stored segment is no longer a prefix of the new
      request — the entire segment is lost and re-written at 1.25x.

  If either fact flips, the pruning conclusion silently inverts and nothing else
  in the codebase would notice: a prune that used to be free starts costing a
  full cache write every time it fires, and the only visible symptom is the
  bill. These tests exist so that change cannot land quietly.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.PromptCache
  alias OptimalSystemAgent.Providers.Registry

  @model "claude-sonnet-4-5"

  # A system message in the block shape `Agent.Context` builds: a cached static
  # prefix followed by an UNMARKED volatile tail. `PromptCache` needs both — the
  # marker to find the stable prefix, the tail to have something to move.
  defp system_message do
    %{
      role: "system",
      content: [
        %{
          "cache_control" => %{"type" => "ephemeral"},
          type: "text",
          text: "static base instructions"
        },
        # Must NOT begin with `PromptCache`'s `@tail_marker` ("## Runtime
        # State") — that string is its idempotency latch, and a fixture that
        # happens to start with it makes `restructure/3` a silent no-op.
        %{type: "text", text: "current time is 22:48, working tree is clean"}
      ]
    }
  end

  defp history do
    [
      %{role: "user", content: "read the file"},
      %{role: "assistant", content: "reading"},
      %{role: "tool", tool_call_id: "t1", name: "file_read", content: "line one\nline two"},
      %{role: "assistant", content: "done"}
    ]
  end

  defp messages, do: [system_message() | history()]

  defp marked?(%{content: parts}) when is_list(parts) do
    Enum.any?(parts, fn
      p when is_map(p) -> Map.has_key?(p, "cache_control") or Map.has_key?(p, :cache_control)
      _ -> false
    end)
  end

  defp marked?(_), do: false

  describe "native Anthropic — history carries no breakpoint" do
    test "restructure/3 does not apply, so no message is marked" do
      out =
        PromptCache.restructure(messages(), OptimalSystemAgent.Providers.Anthropic, model: @model)

      # The system message keeps its own marker; nothing else gains one.
      [_system | rest] = out

      refute Enum.any?(rest, &marked?/1),
             "a cache breakpoint appeared inside message history on the native route — " <>
               "in-place pruning of an old tool result is no longer free there, and " <>
               "docs/design/tool-output-pruning.md must be re-derived"
    end

    test "the message list is returned untouched" do
      assert PromptCache.restructure(
               messages(),
               OptimalSystemAgent.Providers.Anthropic,
               model: @model
             ) == messages()
    end
  end

  describe "OpenRouter → Anthropic — the breakpoint rolls onto the last history message" do
    setup do
      # Precondition: this route must be recognised as cache-honouring at all,
      # otherwise the test below would pass for the wrong reason.
      assert Registry.anthropic_prompt_cache?({:compat, :openrouter}, "anthropic/" <> @model),
             "precondition: the OpenRouter-Anthropic route honours cache_control"

      :ok
    end

    test "some history message is marked" do
      out =
        PromptCache.restructure(messages(), {:compat, :openrouter}, model: "anthropic/" <> @model)

      [_system | rest] = out

      assert Enum.any?(rest, &marked?/1),
             "the rolling history breakpoint is gone — if that is intentional the " <>
               "OpenRouter arm of the pruning analysis becomes the native arm, and " <>
               "the 56-67 turn break-even no longer applies"
    end

    test "the marked message is the last HISTORY message, not the appended tail" do
      out =
        PromptCache.restructure(messages(), {:compat, :openrouter}, model: "anthropic/" <> @model)

      # Shape is [system | history-with-last-marked] ++ [volatile tail].
      # The tail is deliberately unmarked so next turn's new tool results, which
      # are inserted BEFORE it, still extend a valid prefix.
      tail = List.last(out)

      refute marked?(tail),
             "marking the trailing volatile block pins the cached prefix — the " <>
               "measured symptom was a prefix frozen at 26,213 tokens for six turns"

      history_part = out |> Enum.drop(1) |> Enum.drop(-1)

      assert history_part != []
      assert marked?(List.last(history_part))
    end

    test "everything before the marked message is inside the cached segment" do
      out =
        PromptCache.restructure(messages(), {:compat, :openrouter}, model: "anthropic/" <> @model)

      history_part = out |> Enum.drop(1) |> Enum.drop(-1)

      # This is the whole cost argument: the tool result at index 2 sits BEFORE
      # the breakpoint, so it is part of what the provider stored. Rewriting its
      # content is what makes the stored segment stop being a prefix.
      tool_msg = Enum.find(history_part, &(Map.get(&1, :role) == "tool"))

      assert tool_msg, "precondition: a tool result is present in history"

      marked_index = Enum.find_index(history_part, &marked?/1)
      tool_index = Enum.find_index(history_part, &(Map.get(&1, :role) == "tool"))

      # Both must be integers before comparing. Elixir's term ordering makes
      # `2 < nil` TRUE, so an unmarked list would have passed this assertion
      # while proving nothing.
      assert is_integer(marked_index), "no history message carried the breakpoint"
      assert is_integer(tool_index)

      assert tool_index < marked_index,
             "an old tool result sits inside the cached segment on this route — " <>
               "pruning it in place discards the segment"
    end
  end
end
