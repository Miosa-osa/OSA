defmodule OptimalSystemAgent.Tools.Builtins.VaultCheckpointTest do
  @moduledoc """
  Regression coverage: `OptimalSystemAgent.Vault` does not exist (there is no
  vault backend in this build — see the `@allowlist` comment in
  `test/optimal_system_agent/tools/registry_coverage_test.exs`). Before this
  fix, `execute/1` called `OptimalSystemAgent.Vault.checkpoint/1` directly,
  so invoking this tool raised `UndefinedFunctionError` instead of returning
  a normal tool error. This tool is intentionally NOT registered
  (`Tools.Registry.load_builtin_tools/0`), so the model never sees/calls it
  today — this test guards the case where it ever IS invoked directly (a
  future registration mistake, a direct call, etc.) so that never raises.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.VaultCheckpoint

  test "execute/1 never raises — fails gracefully with a clear tool error" do
    assert {:error, message} = VaultCheckpoint.execute(%{"session_id" => "sess-123"})
    assert message =~ "vault checkpoint is not available in this build"
  end

  test "execute/1 does not call OptimalSystemAgent.Vault (which is not defined)" do
    refute Code.ensure_loaded?(OptimalSystemAgent.Vault)
    # If execute/1 still called Vault.checkpoint/1, this call would raise
    # UndefinedFunctionError instead of returning a normal tool error tuple.
    assert {:error, _} = VaultCheckpoint.execute(%{"session_id" => "sess-456"})
  end
end
