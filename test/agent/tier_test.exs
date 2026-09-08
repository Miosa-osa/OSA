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

  # ── max_budget_usd/1 ──────────────────────────────────────────────

  describe "max_budget_usd/1" do
    setup do
      # Snapshot + restore both override knobs so tests don't leak into each
      # other or into the rest of the suite.
      flat = Application.get_env(:optimal_system_agent, :subagent_default_budget_usd)
      per_tier = Application.get_env(:optimal_system_agent, :subagent_max_budget_usd)

      on_exit(fn ->
        restore(:subagent_default_budget_usd, flat)
        restore(:subagent_max_budget_usd, per_tier)
      end)

      :ok
    end

    test "built-in per-tier defaults are on: elite $8 / specialist $4 / utility $1.50" do
      Application.delete_env(:optimal_system_agent, :subagent_default_budget_usd)
      Application.delete_env(:optimal_system_agent, :subagent_max_budget_usd)

      assert Tier.max_budget_usd(:elite) == 8.0
      assert Tier.max_budget_usd(:specialist) == 4.0
      assert Tier.max_budget_usd(:utility) == 1.5
    end

    test "elite has the highest default cap" do
      Application.delete_env(:optimal_system_agent, :subagent_default_budget_usd)
      Application.delete_env(:optimal_system_agent, :subagent_max_budget_usd)

      assert Tier.max_budget_usd(:elite) > Tier.max_budget_usd(:specialist)
      assert Tier.max_budget_usd(:specialist) > Tier.max_budget_usd(:utility)
    end

    test "flat global override applies to every tier" do
      Application.delete_env(:optimal_system_agent, :subagent_max_budget_usd)
      Application.put_env(:optimal_system_agent, :subagent_default_budget_usd, 2.0)

      assert Tier.max_budget_usd(:elite) == 2.0
      assert Tier.max_budget_usd(:specialist) == 2.0
      assert Tier.max_budget_usd(:utility) == 2.0
    end

    test "per-tier map override wins over both the flat knob and the default" do
      Application.put_env(:optimal_system_agent, :subagent_default_budget_usd, 2.0)
      Application.put_env(:optimal_system_agent, :subagent_max_budget_usd, %{elite: 25.0})

      # elite: from the per-tier map
      assert Tier.max_budget_usd(:elite) == 25.0
      # specialist: no per-tier entry -> falls back to the flat global override
      assert Tier.max_budget_usd(:specialist) == 2.0
    end

    test "per-tier entry falls back to built-in default when flat knob unset" do
      Application.delete_env(:optimal_system_agent, :subagent_default_budget_usd)
      Application.put_env(:optimal_system_agent, :subagent_max_budget_usd, %{elite: 30.0})

      assert Tier.max_budget_usd(:elite) == 30.0
      # utility has no entry and no flat override -> built-in default
      assert Tier.max_budget_usd(:utility) == 1.5
    end

    test "tier_info exposes the per-tier budget" do
      Application.delete_env(:optimal_system_agent, :subagent_default_budget_usd)
      Application.delete_env(:optimal_system_agent, :subagent_max_budget_usd)

      assert Tier.tier_info(:elite).max_budget_usd == 8.0
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

  # Restore an application env key to its snapshotted value (nil => delete),
  # so budget-override tests never leak into the rest of the suite.
  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)
end
