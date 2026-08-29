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

  describe "speed/priority tier biases tier and provider order" do
    # Capture the tier the router asks model_for for, so we can assert the
    # priority bias without depending on a real model table.
    defp capture_tier_router(task, config, extra \\ []) do
      test_pid = self()

      opts =
        [
          candidates: [:paid_primary, :free_local],
          configured?: fn _ -> true end,
          model_for: fn tier, provider ->
            send(test_pid, {:asked, tier, provider})
            "#{provider}-#{tier}-model"
          end,
          tool_call: fn _, _ -> true end,
          context_window: fn _ -> 200_000 end,
          vision_capable: fn _, _ -> true end
        ] ++ extra

      DelegationRouter.resolve(task, config, opts)
    end

    test "loose steps the quality tier DOWN one, floored at :specialist" do
      # elite → specialist under loose
      routed =
        capture_tier_router("do it", %{provider: :paid_primary, tier: :elite, priority: "loose"})

      assert_received {:asked, :specialist, _}
      assert routed.priority == :loose
      assert routed.model_reason =~ "priority: loose"
    end

    test "loose never drops below :specialist (stays tool-capable)" do
      capture_tier_router("do it", %{
        provider: :paid_primary,
        tier: :specialist,
        priority: "loose"
      })

      # specialist stepped toward utility would be :utility, but loose is floored
      assert_received {:asked, :specialist, _}
    end

    test "immediate steps the quality tier UP toward :elite" do
      capture_tier_router("do it", %{
        provider: :paid_primary,
        tier: :specialist,
        priority: "immediate"
      })

      assert_received {:asked, :elite, _}
    end

    test "loose prefers a free/local provider over the paid primary" do
      # FallbackChain.free?/1 decides; :ollama is free in the default set. Use it
      # as the free candidate so ordering puts it first for loose.
      test_pid = self()

      DelegationRouter.resolve(
        "do it",
        %{provider: :openai, tier: :specialist, priority: "loose"},
        candidates: [:openai, :ollama],
        configured?: fn _ -> true end,
        model_for: fn _tier, provider ->
          send(test_pid, {:picked, provider})
          "#{provider}-m"
        end,
        tool_call: fn _, _ -> true end,
        context_window: fn _ -> 200_000 end,
        vision_capable: fn _, _ -> true end
      )

      # The FIRST provider offered to model_for under loose must be the free one.
      assert_received {:picked, :ollama}
    end

    test "standard (default) leaves tier and order unchanged" do
      routed = capture_tier_router("do it", %{provider: :paid_primary, tier: :specialist})
      assert_received {:asked, :specialist, :paid_primary}
      assert routed.priority == :standard
      refute routed.model_reason =~ "priority:"
    end
  end

  describe "cost-aware routing (#10): loose prefers the cheapest observed model" do
    alias OptimalSystemAgent.Agent.CostObservations

    setup do
      CostObservations.reset()
      on_exit(&CostObservations.reset/0)
      :ok
    end

    test "among two capable loose candidates, the cheaper observed one wins" do
      CostObservations.record(:paid_a, "paid_a-specialist-model", 1.0)
      CostObservations.record(:paid_b, "paid_b-specialist-model", 0.2)

      routed =
        DelegationRouter.resolve(
          "do it",
          %{provider: :paid_a, tier: :specialist, priority: "loose"},
          candidates: [:paid_a, :paid_b],
          configured?: fn _ -> true end,
          model_for: fn tier, provider -> "#{provider}-#{tier}-model" end,
          tool_call: fn _, _ -> true end,
          context_window: fn _ -> 200_000 end,
          vision_capable: fn _, _ -> true end
        )

      assert routed.provider == :paid_b, "cheaper observed model should be chosen for loose"
    end

    test "with no observations, order is unchanged (first compatible)" do
      routed =
        DelegationRouter.resolve(
          "do it",
          %{provider: :paid_a, tier: :specialist, priority: "loose"},
          candidates: [:paid_a, :paid_b],
          configured?: fn _ -> true end,
          model_for: fn tier, provider -> "#{provider}-#{tier}-model" end,
          tool_call: fn _, _ -> true end,
          context_window: fn _ -> 200_000 end,
          vision_capable: fn _, _ -> true end
        )

      assert routed.provider == :paid_a
    end
  end
end
