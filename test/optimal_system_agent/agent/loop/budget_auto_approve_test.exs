defmodule OptimalSystemAgent.Agent.Loop.BudgetAutoApproveTest do
  @moduledoc """
  Phase 3 governance: an unattended agent with a per-session spend cap and the
  :budget_auto_approve policy enabled acts freely UP TO the cap, then falls
  closed. The policy only ever converts a would-fail-closed :ask into an allow;
  it runs after every security check and never overrides a block. A saved `ask`
  rule on the tool forces the interactive path so these tests exercise exactly
  that decision point.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Settings

  @flag_file Path.join(System.tmp_dir!(), "osa-bap-settings.json")

  setup do
    prior_policy = Application.get_env(:optimal_system_agent, :budget_auto_approve, false)
    prior_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)

    prior_interactive =
      Application.get_env(:optimal_system_agent, :interactive_permissions, false)

    # The test env sets :non_interactive_permission_bypass true (auto-allow all
    # unattended). Turn it OFF here so the budget policy / fail-closed actually
    # decide, which is the whole point of these tests.
    prior_bypass =
      Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

    Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

    # Force an ASK rule on shell_execute so it needs approval, and mark the
    # session unattended so the decision falls to non_interactive_decision.
    File.write!(@flag_file, Jason.encode!(%{"permissions" => %{"ask" => ["shell_execute"]}}))
    Application.put_env(:optimal_system_agent, :settings_flag_path, @flag_file)
    Application.put_env(:optimal_system_agent, :interactive_permissions, false)
    Settings.reset_cache()

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :budget_auto_approve, prior_policy)
      Application.put_env(:optimal_system_agent, :interactive_permissions, prior_interactive)
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, prior_bypass)

      case prior_flag do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        p -> Application.put_env(:optimal_system_agent, :settings_flag_path, p)
      end

      File.rm(@flag_file)
      Settings.reset_cache()
    end)

    :ok
  end

  defp unattended(overrides),
    do:
      struct(
        Loop,
        [
          session_id: "bap-#{System.unique_integer([:positive])}",
          channel: :internal,
          permission_mode: :ask
        ] ++
          overrides
      )

  defp tool,
    do: %{
      id: "tc-#{System.unique_integer([:positive])}",
      name: "shell_execute",
      arguments: %{"command" => "echo hi"}
    }

  test "within budget + policy on → allowed" do
    Application.put_env(:optimal_system_agent, :budget_auto_approve, true)

    assert ToolExecutor.approve_tool_call(
             tool(),
             unattended(max_budget_usd: 1.0, session_cost_usd: 0.10)
           ) == :allow
  end

  test "over budget + policy on → blocked (bounded by dollars)" do
    Application.put_env(:optimal_system_agent, :budget_auto_approve, true)

    assert {:blocked, _} =
             ToolExecutor.approve_tool_call(
               tool(),
               unattended(max_budget_usd: 1.0, session_cost_usd: 2.0)
             )
  end

  test "policy OFF → fails closed even within budget (unchanged default)" do
    Application.put_env(:optimal_system_agent, :budget_auto_approve, false)

    assert {:blocked, _} =
             ToolExecutor.approve_tool_call(
               tool(),
               unattended(max_budget_usd: 1.0, session_cost_usd: 0.10)
             )
  end

  test "no cap set → policy does not fire (blocked)" do
    Application.put_env(:optimal_system_agent, :budget_auto_approve, true)

    assert {:blocked, _} =
             ToolExecutor.approve_tool_call(
               tool(),
               unattended(max_budget_usd: nil, session_cost_usd: 0.10)
             )
  end
end
