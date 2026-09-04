defmodule OptimalSystemAgent.Providers.AstraSupportTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.{
    OpenAIModels,
    OpenAICodex,
    OpenAICompat,
    OpenAICompatProvider,
    OpenAIResponses,
    Registry
  }

  test "Astra is offered with capabilities and provider-specific context budgets" do
    assert "gpt-6-astra" in OpenAICodex.available_models()
    assert "gpt-6-astra" in OpenAICompatProvider.available_models(:openai)

    assert %{
             vision: true,
             tools: true,
             reasoning: true,
             max_output: 128_000,
             pricing: {10.0, 50.0}
           } = OpenAIModels.model("gpt-6-astra")

    assert Registry.effective_context_window("gpt-6-astra", :openai_codex) == 272_000
    assert Registry.effective_context_window_info("gpt-6-astra", :openai_codex) == {:ok, 272_000}
  end

  test "only direct OpenAI Astra switches from chat completions to Responses" do
    assert OpenAICompatProvider.transport(:openai, "gpt-6-astra") == OpenAIResponses
    assert OpenAICompatProvider.transport(:openai, "gpt-5.6-sol") == OpenAICompat
    assert OpenAICompatProvider.transport(:openrouter, "gpt-6-astra") == OpenAICompat
  end

  test "Astra effort and fast tier stay independent with tools preserved" do
    for {effort, expected} <- [
          {:low, "low"},
          {:medium, "medium"},
          {:high, "high"},
          {:xhigh, "xhigh"},
          {:max, "max"},
          {:ultra, "max"}
        ] do
      body =
        OpenAIResponses.build_body(
          "gpt-6-astra",
          [%{role: "user", content: "hi"}],
          [
            effort: effort,
            service_tier: "priority",
            temperature: 0.5,
            tools: [
              %{
                name: "inspect",
                description: "Inspect",
                parameters: %{"type" => "object", "properties" => %{}}
              }
            ]
          ],
          true
        )

      assert body.reasoning.effort == expected
      assert body.service_tier == "priority"
      assert length(body.tools) == 1
      refute Map.has_key?(body, :temperature)
      assert body.store == false
    end
  end
end
