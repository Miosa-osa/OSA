defmodule OptimalSystemAgent.Agent.TierTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Tier

  describe "Ollama agent model selection" do
    setup do
      old_model = Application.get_env(:optimal_system_agent, :ollama_model)
      old_tiers = :persistent_term.get(:osa_ollama_tiers, :missing)
      old_overrides = :persistent_term.get(:osa_tier_overrides, :missing)

      on_exit(fn ->
        if old_model,
          do: Application.put_env(:optimal_system_agent, :ollama_model, old_model),
          else: Application.delete_env(:optimal_system_agent, :ollama_model)

        restore_term(:osa_ollama_tiers, old_tiers)
        restore_term(:osa_tier_overrides, old_overrides)
      end)

      :ok
    end

    test "the explicitly selected model beats stale automatic tier assignments" do
      Application.put_env(:optimal_system_agent, :ollama_model, "glm-5.2:cloud")

      :persistent_term.put(:osa_ollama_tiers, %{
        elite: "llama3.2:3b",
        specialist: "nomic-embed-text:latest",
        utility: "qwen3-embedding:0.6b"
      })

      assert Tier.model_for(:specialist, :ollama) == "glm-5.2:cloud"
    end

    test "automatic tiers exclude embedding and undersized non-agent models" do
      models = [
        %{name: "llama3.2:3b", size: 2_019_393_189},
        %{name: "qwen3-coder:480b-cloud", size: 382},
        %{name: "qwen3-embedding:0.6b", size: 639_150_858},
        %{name: "nomic-embed-text:latest", size: 274_302_450}
      ]

      assert Tier.assign_ollama_tiers(models) == %{
               elite: "qwen3-coder:480b-cloud",
               specialist: "qwen3-coder:480b-cloud",
               utility: "qwen3-coder:480b-cloud"
             }
    end
  end

  defp restore_term(key, :missing), do: :persistent_term.erase(key)
  defp restore_term(key, value), do: :persistent_term.put(key, value)

  # ── max_agents/1 ──────────────────────────────────────────────────

  describe "max_agents/1" do
    test "elite allows 50 agents" do
      assert Tier.max_agents(:elite) == 50
    end

    test "specialist allows 30 agents" do
      assert Tier.max_agents(:specialist) == 30
    end

    test "utility allows 10 agents" do
      assert Tier.max_agents(:utility) == 10
    end
  end

  # ── tier_for_complexity/1 ─────────────────────────────────────────

  describe "tier_for_complexity/1" do
    test "low complexity maps to utility" do
      assert Tier.tier_for_complexity(1) == :utility
      assert Tier.tier_for_complexity(2) == :utility
      assert Tier.tier_for_complexity(3) == :utility
    end

    test "medium complexity maps to specialist" do
      assert Tier.tier_for_complexity(4) == :specialist
      assert Tier.tier_for_complexity(5) == :specialist
      assert Tier.tier_for_complexity(6) == :specialist
    end

    test "high complexity maps to elite" do
      assert Tier.tier_for_complexity(7) == :elite
      assert Tier.tier_for_complexity(8) == :elite
      assert Tier.tier_for_complexity(9) == :elite
      assert Tier.tier_for_complexity(10) == :elite
    end
  end

  # ── budget_for/1 ──────────────────────────────────────────────────

  describe "budget_for/1" do
    test "returns budget map for each tier" do
      for tier <- [:elite, :specialist, :utility] do
        budget = Tier.budget_for(tier)
        assert is_map(budget)
        assert Map.has_key?(budget, :total)
        assert budget.total > 0
      end
    end

    test "elite has highest total budget" do
      assert Tier.total_budget(:elite) > Tier.total_budget(:specialist)
      assert Tier.total_budget(:specialist) > Tier.total_budget(:utility)
    end
  end

  # ── max_response_tokens/1 ─────────────────────────────────────────

  describe "max_response_tokens/1" do
    test "elite gets most response tokens" do
      assert Tier.max_response_tokens(:elite) > Tier.max_response_tokens(:specialist)
      assert Tier.max_response_tokens(:specialist) > Tier.max_response_tokens(:utility)
    end
  end

  # ── tier_info/1 ───────────────────────────────────────────────────

  describe "tier_info/1" do
    test "returns complete tier info with max_agents reflecting new ceilings" do
      info = Tier.tier_info(:elite)
      assert info.max_agents == 50

      info = Tier.tier_info(:specialist)
      assert info.max_agents == 30

      info = Tier.tier_info(:utility)
      assert info.max_agents == 10
    end
  end
end
