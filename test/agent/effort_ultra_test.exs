defmodule OptimalSystemAgent.Agent.EffortUltraTest do
  @moduledoc """
  The `:ultra` effort tier (OSA's `ultracode`) + the effort-ladder rank helpers
  that gate dynamic-workflow fan-out.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    previous_session = session_effort_level()
    Effort.set(:medium)

    on_exit(fn ->
      restore_session_effort_level(previous_session)

      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  test "ultra is a real level above xhigh" do
    ultra = Effort.get(:ultra)
    xhigh = Effort.get(:xhigh)

    assert ultra.label == "Ultra"
    assert ultra.description =~ "dynamic workflows"
    assert ultra.thinking_budget == 64_000
    assert ultra.thinking_budget > xhigh.thinking_budget
    assert ultra.max_iterations >= 4000
    assert ultra.max_iterations > xhigh.max_iterations
    assert ultra.tool_budget >= xhigh.tool_budget
  end

  test "levels/0 lists ultra highest" do
    assert Effort.levels() == [:fast, :medium, :high, :xhigh, :ultra]
    assert List.last(Effort.levels()) == :ultra
  end

  test "rank orders fast < medium < high < xhigh < ultra" do
    ranks = Enum.map([:fast, :medium, :high, :xhigh, :ultra], &Effort.rank/1)
    assert ranks == Enum.sort(ranks)
    assert Effort.rank(:ultra) > Effort.rank(:xhigh)
    assert Effort.rank(:bogus) == -1
  end

  test "at_least?/2 and current_at_least?/1 gate on the ladder" do
    assert Effort.at_least?(:ultra, :ultra)
    assert Effort.at_least?(:ultra, :xhigh)
    refute Effort.at_least?(:xhigh, :ultra)
    refute Effort.at_least?(:high, :ultra)

    Effort.set(:ultra)
    assert Effort.current() == :ultra
    assert Effort.current_at_least?(:ultra)

    Effort.set(:xhigh)
    refute Effort.current_at_least?(:ultra)
    assert Effort.current_at_least?(:xhigh)
  end

  test "set/1 accepts ultra and drives the ultra budgets" do
    assert :ok = Effort.set(:ultra)
    assert Effort.current() == :ultra
    assert Effort.thinking_budget() == 64_000
    assert Effort.max_iterations() >= 4000
  end

  describe "legacy back-compat (normalize/1)" do
    test "normalize maps legacy atoms and strings to the new ladder" do
      assert Effort.normalize(:low) == :fast
      assert Effort.normalize(:max) == :xhigh
      assert Effort.normalize("low") == :fast
      assert Effort.normalize("max") == :xhigh
      assert Effort.normalize("off") == :fast
      # Unchanged levels normalize to themselves.
      assert Effort.normalize(:medium) == :medium
      assert Effort.normalize(:xhigh) == :xhigh
      assert Effort.normalize("ultra") == :ultra
      # Unknown values pass through unchanged.
      assert Effort.normalize(:bogus) == :bogus
    end

    test "set/1 accepts legacy :low (aliases to :fast)" do
      assert :ok = Effort.set(:low)
      assert Effort.current() == :fast
      assert Effort.fast_mode?()
      assert Effort.thinking_budget() == 0
    end

    test "set/1 accepts legacy :max (aliases to :xhigh)" do
      assert :ok = Effort.set(:max)
      assert Effort.current() == :xhigh
      assert Effort.thinking_budget() == 32_000
      assert Effort.max_iterations() >= 2000
    end

    test "current/0 normalizes a persisted legacy app-env value" do
      Application.put_env(:optimal_system_agent, :effort_level, :max)
      # Clear any session override so app-env is what current/0 reads.
      if :ets.whereis(:osa_settings) != :undefined do
        :ets.delete(:osa_settings, {:session, :effort_level})
      end

      assert Effort.current() == :xhigh
    end

    test "legacy get/1 and rank/1 still resolve" do
      assert Effort.get(:low).label == "fast"
      assert Effort.get(:max).label == "xhigh"
      assert Effort.rank(:low) == Effort.rank(:fast)
      assert Effort.rank(:max) == Effort.rank(:xhigh)
    end
  end

  defp session_effort_level do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp restore_session_effort_level(:missing) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.delete(:osa_settings, {:session, :effort_level})
    end
  end

  defp restore_session_effort_level({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.insert(:osa_settings, {{:session, :effort_level}, value})
    end
  end
end
