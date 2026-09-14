defmodule OptimalSystemAgent.Agent.ContextMultimodalAccountingTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Agent.{Context, Compactor}

  test "pressure events use their advertised denominator, including below one percent" do
    session = "accounting-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")

    state = %{
      session_id: session,
      model: "gpt-4o",
      provider: :openai,
      last_input_tokens: 640,
      messages: []
    }

    OptimalSystemAgent.Agent.Loop.Telemetry.emit_context_pressure(state)
    assert_receive {:osa_event, %{event: :context_pressure} = event}
    assert event.estimated_tokens == 640
    assert event.utilization == Float.round(640 / event.max_tokens * 100, 1)
    assert event.utilization < 1.0
  end

  test "budget breakdown and prompt builder count screenshots without base64 inflation" do
    for provider <- [:openai_codex, :openai, :anthropic, :google] do
      state = %{
        session_id: "image-budget-#{provider}",
        channel: :cli,
        plan_mode: false,
        working_dir: "/tmp",
        provider: provider,
        model: "gpt-6-astra",
        effective_context_window: 272_000,
        messages: [
          %{
            role: "tool",
            content: [%{type: "image", source: %{data: String.duplicate("abcd", 1_000_000)}}]
          }
        ]
      }

      budget = Context.token_budget(state)
      assert budget.tool_result_tokens == 1_604

      assert budget.occupied_tokens ==
               budget.static_base_tokens + budget.dynamic_context_tokens +
                 budget.conversation_tokens + budget.tool_result_tokens +
                 budget.tool_schema_tokens
    end
  end

  test "all supported image dialects share the compactor estimate regardless of payload size" do
    for type <- ["image", "image_url", "input_image"],
        keys <- [:atoms, :strings] do
      make = fn size ->
        block = %{type: type, source: %{data: String.duplicate("abcd", size)}}
        msg = %{role: "tool", content: [block]}
        if keys == :strings, do: Jason.decode!(Jason.encode!(msg)), else: msg
      end

      small = [make.(1)]
      large = [make.(1_000_000)]
      assert Context.estimate_tokens_messages(large) == Compactor.estimate_tokens(large)
      assert Context.estimate_tokens_messages(large) == Context.estimate_tokens_messages(small)
      assert Context.estimate_tokens_messages(large) == 1_604
    end
  end

  test "nested tool results and standalone image maps do not become encoded text" do
    image = %{
      "type" => "input_image",
      "image_url" => "data:image/png;base64," <> String.duplicate("abcd", 100_000)
    }

    for content <- [image, [%{"type" => "tool_result", "content" => [image]}]] do
      assert Context.estimate_tokens_messages([%{role: :tool, content: content}]) == 1_604
    end
  end

  test "text, tool arguments, and replayed reasoning are still counted" do
    msg = %{
      role: "assistant",
      content: "hello",
      reasoning_content: "Check the result",
      tool_calls: [%{name: "inspect", arguments: %{"path" => "/tmp/example"}}, nil]
    }

    assert Context.estimate_tokens_messages([msg]) == Compactor.estimate_tokens([msg])

    assert Context.estimate_tokens_messages([msg]) >
             Context.estimate_tokens_messages([%{role: "assistant", content: "hello"}])
  end
end
