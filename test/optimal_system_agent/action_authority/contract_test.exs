defmodule OptimalSystemAgent.ActionAuthority.ContractTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.ActionAuthority.Contract

  test "loads the complete generated OSA alias catalog" do
    aliases = Contract.osa_aliases()

    assert map_size(aliases) == 25
    assert aliases["shell_execute:miosa"] == "sandbox.exec"
    assert aliases["computer_use:screenshot"] == "computer.screenshot"
    assert aliases["computer_use:triple_click"] == "computer.triple.click"
  end

  test "unknown aliases fail closed" do
    assert {:error, :unknown_alias} = Contract.capability_for("computer_use:future_action")
  end
end
