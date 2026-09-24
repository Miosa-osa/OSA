defmodule OptimalSystemAgent.Agent.Loop.AdvisorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Advisor
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev = %{
      advisor_enabled: Application.fetch_env(:optimal_system_agent, :advisor_enabled),
      advisor_auto_enabled: Application.fetch_env(:optimal_system_agent, :advisor_auto_enabled),
      advisor_provider: Application.fetch_env(:optimal_system_agent, :advisor_provider),
      advisor_model: Application.fetch_env(:optimal_system_agent, :advisor_model),
      advisor_cost_cap_usd: Application.fetch_env(:optimal_system_agent, :advisor_cost_cap_usd)
    }

    Application.put_env(:optimal_system_agent, :advisor_provider, :mock)
    # A real, priced model id (Anthropic's rate card) so cost-cap tests exercise
    # a genuinely non-zero cost — `:mock` as the PROVIDER still routes the call
    # to `MockProvider` (which ignores the model string and returns canned
    # text); `Pricing.cost/2` prices purely off the model string, not the
    # provider, so this combination is deterministic and free of network I/O.
    Application.put_env(:optimal_system_agent, :advisor_model, "claude-haiku-4-5")
    Application.put_env(:optimal_system_agent, :advisor_enabled, true)
    Application.put_env(:optimal_system_agent, :advisor_auto_enabled, true)
    Application.delete_env(:optimal_system_agent, :advisor_cost_cap_usd)

    MockProvider.reset()
    MockProvider.reset_final_texts()
    Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
    Application.delete_env(:optimal_system_agent, :mock_provider_error)
    Application.delete_env(:optimal_system_agent, :mock_provider_usage)

    on_exit(fn ->
      for {key, val} <- prev do
        case val do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end

      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
      Application.delete_env(:optimal_system_agent, :mock_provider_error)
      Application.delete_env(:optimal_system_agent, :mock_provider_usage)
    end)

    :ok
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{session_id: "advisor-#{System.unique_integer([:positive])}", messages: []},
      overrides
    )
  end

  describe "configured_pair/1 and enabled?/1" do
    test "reads the configured provider/model" do
      assert Advisor.configured_pair(state()) == {:mock, "claude-haiku-4-5"}
      assert Advisor.enabled?(state())
    end

    test "unconfigured model disables the advisor" do
      Application.delete_env(:optimal_system_agent, :advisor_model)
      refute Advisor.enabled?(state())
      assert Advisor.configured_pair(state()) == nil
    end

    test "explicitly disabled via advisor_enabled" do
      Application.put_env(:optimal_system_agent, :advisor_enabled, false)
      refute Advisor.enabled?(state())
    end

    test "auto_enabled?/1 is independent of the manual path" do
      Application.put_env(:optimal_system_agent, :advisor_auto_enabled, false)
      assert Advisor.enabled?(state())
      refute Advisor.auto_enabled?(state())
    end
  end

  describe "consult/3 — success path" do
    test "returns advice, provider, model, and a non-negative cost" do
      Application.put_env(
        :optimal_system_agent,
        :mock_provider_final_text,
        "Looks solid, ship it."
      )

      Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
        input_tokens: 100,
        output_tokens: 50
      })

      assert {:ok, %{advice: advice, provider: :mock, model: "claude-haiku-4-5", cost_usd: cost}} =
               Advisor.consult(state(), "Should I proceed?")

      assert advice == "Looks solid, ship it."
      assert is_number(cost) and cost >= 0
    end

    test "records spend against the turn's budget" do
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Advice text.")

      Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      })

      s = state()
      assert Advisor.spent(s) == 0.0
      {:ok, %{cost_usd: cost}} = Advisor.consult(s, "question")
      assert cost > 0.0
      assert_in_delta Advisor.spent(s), cost, 0.0001
    end
  end

  describe "consult/3 — gating" do
    test "advisor_disabled when turned off" do
      Application.put_env(:optimal_system_agent, :advisor_enabled, false)
      assert Advisor.consult(state(), "q") == {:error, :advisor_disabled}
    end

    test "advisor_not_configured when no model is set" do
      Application.delete_env(:optimal_system_agent, :advisor_model)
      assert Advisor.consult(state(), "q") == {:error, :advisor_not_configured}
    end

    test "cost_cap_reached once the turn's spend hits the configured cap" do
      Application.put_env(:optimal_system_agent, :advisor_cost_cap_usd, 0.0000001)
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Advice.")

      Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
        input_tokens: 1000,
        output_tokens: 1000
      })

      s = state()
      assert {:ok, _} = Advisor.consult(s, "first question")
      assert Advisor.consult(s, "second question") == {:error, :cost_cap_reached}
    end

    test "a provider error is surfaced, not swallowed" do
      Application.put_env(:optimal_system_agent, :mock_provider_error, "boom")
      assert {:error, "boom"} = Advisor.consult(state(), "q")
    end
  end

  describe "reset_turn_budget/1" do
    test "starts a fresh spend bucket for the session" do
      Application.put_env(:optimal_system_agent, :advisor_cost_cap_usd, 0.0000001)
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Advice.")

      Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
        input_tokens: 1000,
        output_tokens: 1000
      })

      s = state(%{session_id: "advisor-reset-#{System.unique_integer([:positive])}"})
      assert {:ok, _} = Advisor.consult(s, "q1")
      assert Advisor.consult(s, "q2") == {:error, :cost_cap_reached}

      Advisor.reset_turn_budget(s.session_id)
      assert Advisor.spent(s) == 0.0
      assert {:ok, _} = Advisor.consult(s, "q3")
    end
  end

  describe "frame/1" do
    test "wraps advice in the advice-not-instruction header" do
      framed = Advisor.frame("Do the thing.")
      assert framed =~ "ADVISOR RECOMMENDATION"
      assert framed =~ "not an instruction"
      assert framed =~ "Do the thing."
    end
  end

  describe "maybe_auto_consult/3" do
    test "appends a framed system message on success" do
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Consider X.")

      s = state()
      result = Advisor.maybe_auto_consult(s, :plan_made, "a plan was proposed")

      assert length(result.messages) == length(s.messages) + 1
      [added] = result.messages -- s.messages
      assert added.role == "system"
      assert added.content =~ "ADVISOR RECOMMENDATION"
      assert added.content =~ "Consider X."
    end

    test "returns state unchanged when the advisor is disabled" do
      Application.put_env(:optimal_system_agent, :advisor_enabled, false)
      s = state()
      assert Advisor.maybe_auto_consult(s, :risky_action, "about to run rm -rf") == s
    end

    test "returns state unchanged when auto-consult is off but manual stays on" do
      Application.put_env(:optimal_system_agent, :advisor_auto_enabled, false)
      s = state()
      assert Advisor.maybe_auto_consult(s, :stuck, "repeated failures") == s
      assert Advisor.enabled?(s)
    end

    test "returns state unchanged on a provider error rather than raising" do
      Application.put_env(:optimal_system_agent, :mock_provider_error, "boom")
      s = state()
      assert Advisor.maybe_auto_consult(s, :plan_made, "note") == s
    end
  end
end
