defmodule OptimalSystemAgent.Agent.DelegationRouterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.DelegationRouter

  test "selects the first configured model that satisfies a tool-heavy delegated task" do
    config = %{provider: :first, tier: :specialist}

    routed =
      DelegationRouter.resolve("Inspect the repository and edit the broken module", config,
        candidates: [:first, :second],
        configured?: fn _ -> true end,
        model_for: fn
          _, :first -> "chat-only"
          _, :second -> "tools-model"
        end,
        tool_call: fn
          :first, _ -> false
          :second, _ -> true
        end,
        context_window: fn _ -> 200_000 end
      )

    assert routed.provider == :second
    assert routed.model == "tools-model"
    assert routed.model_reason =~ "supports tools"
    assert routed.model_requirements == ["tools"]
  end

  test "keeps an explicit model and explains that operator choice" do
    routed =
      DelegationRouter.resolve("Review this file", %{provider: :openai, model: "gpt-explicit"})

    assert routed.provider == :openai
    assert routed.model == "gpt-explicit"
    assert routed.model_reason =~ "explicit"
  end

  test "recognizes large-context and vision work in the task itself" do
    assert DelegationRouter.requirements(
             "Audit the entire repository and compare the attached screenshot"
           ) == [:tools, :large_context, :vision]
  end

  test "routes an image task away from a model known to lack vision" do
    routed =
      DelegationRouter.resolve("Inspect the attached screenshot", %{provider: :first},
        candidates: [:first, :second],
        configured?: fn _ -> true end,
        model_for: fn _, provider -> "#{provider}-model" end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 200_000 end,
        vision_capable: fn provider, _ -> provider == :second end
      )

    assert routed.provider == :second
    assert routed.model_requirements == ["tools", "vision"]
  end

  test "does not claim unknown context capacity satisfies a large-context task" do
    routed =
      DelegationRouter.resolve("Audit the entire repository", %{provider: :first},
        candidates: [:first, :second],
        configured?: fn _ -> true end,
        model_for: fn _, provider -> "#{provider}-model" end,
        tool_call: fn _, _ -> true end,
        context_window: fn
          "first-model" -> nil
          "second-model" -> 200_000
        end
      )

    assert routed.provider == :second
  end

  test "degrades to a tools-capable model when no vision model exists rather than blocking" do
    routed =
      DelegationRouter.resolve("Inspect the attached screenshot", %{provider: :first},
        candidates: [:first],
        configured?: fn _ -> true end,
        model_for: fn _, _ -> "text-only" end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 200_000 end,
        vision_capable: fn _, _ -> false end
      )

    refute Map.has_key?(routed, :routing_error)
    assert routed.provider == :first
    assert routed.model == "text-only"
    assert routed.model_reason =~ "proceeding without it"
    assert routed.model_reason =~ "vision-aware task"
    # the ORIGINAL requirements are still reported, transparently
    assert routed.model_requirements == ["tools", "vision"]
  end

  test "blocks delegation only when not even a tools-capable model exists" do
    routed =
      DelegationRouter.resolve("Inspect the attached screenshot", %{provider: :first},
        candidates: [:first],
        configured?: fn _ -> true end,
        model_for: fn _, _ -> "text-only" end,
        tool_call: fn _, _ -> false end,
        context_window: fn _ -> 200_000 end,
        vision_capable: fn _, _ -> false end
      )

    assert routed.routing_error =~ "no configured model"
    assert routed.model_reason =~ "blocked"
    refute Map.has_key?(routed, :model)
  end

  test "an incidental vision-like word does not force a vision requirement" do
    # "reimagine", "visualize", "images/" style substrings must not trigger vision
    assert DelegationRouter.requirements("Reimagine and visualize the imagestore module") ==
             [:tools]
  end

  test "drops large-context before refusing when no huge-context model is known" do
    routed =
      DelegationRouter.resolve("Audit the entire repository codebase", %{provider: :first},
        candidates: [:first],
        configured?: fn _ -> true end,
        model_for: fn _, _ -> "small-ctx" end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 8_000 end
      )

    refute Map.has_key?(routed, :routing_error)
    assert routed.provider == :first
    assert routed.model_reason =~ "proceeding without it"
  end
end
