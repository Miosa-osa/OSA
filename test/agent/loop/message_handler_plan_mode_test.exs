defmodule OptimalSystemAgent.Agent.Loop.MessageHandlerPlanModeTest do
  @moduledoc """
  `MessageHandler.run_plan_mode/1` — investigative plan mode.

  Plan mode now runs the REAL `ReactLoop` (multi-step, tools available) with
  `permission_mode: :plan` temporarily forced, instead of a single no-tools
  LLM call. These tests drive `ReactLoop.run/1` through its cancel-flag
  short-circuit (same technique as `InterruptTest`) so they never hit a live
  LLM provider, while still exercising `run_plan_mode/1`'s own logic: the
  permission-mode swap + restore, the interrupt guard, and the plan_mode flag
  clear.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.PlanStore

  @cancel_table :osa_cancel_flags

  defp base_state(overrides \\ %{}) do
    session_id = "plan-mode-mh-test-#{System.unique_integer([:positive, :monotonic])}"

    Map.merge(
      %{
        session_id: session_id,
        iteration: 0,
        messages: [%{role: "user", content: "plan out a refactor"}],
        model: nil,
        provider: nil,
        plan_mode: true,
        permission_mode: :ask
      },
      overrides
    )
  end

  setup do
    on_exit(fn -> :ok end)
    :ok
  end

  describe "run_plan_mode/1 — investigative loop wiring" do
    test "forces permission_mode: :plan for the duration of the investigative loop, then restores it" do
      state = base_state(%{permission_mode: :accept_edits})
      :ets.insert(@cancel_table, {state.session_id, true})

      {:error, :interrupted, final_state} = MessageHandler.run_plan_mode(state)

      # Restored to whatever it was before entering plan mode — NOT left at :plan.
      assert final_state.permission_mode == :accept_edits
    end

    test "clears plan_mode on the returned state regardless of outcome" do
      state = base_state()
      :ets.insert(@cancel_table, {state.session_id, true})

      {:error, :interrupted, final_state} = MessageHandler.run_plan_mode(state)

      refute final_state.plan_mode
    end

    test "an interrupted investigative turn does not stash a pending plan" do
      state = base_state()
      :ets.insert(@cancel_table, {state.session_id, true})

      MessageHandler.run_plan_mode(state)

      assert PlanStore.get(state.session_id) == nil
      assert PlanStore.read_plan_file(state.session_id) == {:error, :not_found}
    end

    test "default permission_mode (:ask) is restored after an interrupted plan turn" do
      state = base_state()
      :ets.insert(@cancel_table, {state.session_id, true})

      {:error, :interrupted, final_state} = MessageHandler.run_plan_mode(state)

      assert final_state.permission_mode == :ask
    end
  end
end
