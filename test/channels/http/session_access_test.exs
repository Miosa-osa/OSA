defmodule OptimalSystemAgent.Channels.HTTP.SessionAccessTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.HTTP.SessionAccess

  test "stable local identity can reclaim a legacy random TUI owner on loopback" do
    assert :ok == SessionAccess.authorize_owner("tui_1786981622480213000", "local", true)
  end

  test "legacy-owner compatibility never crosses a network boundary" do
    assert {:error, :not_found} ==
             SessionAccess.authorize_owner("tui_1786981622480213000", "local", false)
  end

  test "one explicit user cannot open another explicit user's session" do
    assert {:error, :not_found} == SessionAccess.authorize_owner("alice", "bob", true)
    assert {:error, :not_found} == SessionAccess.authorize_owner("alice", "bob", false)
  end

  test "the exact owner remains authorized" do
    assert :ok == SessionAccess.authorize_owner("alice", "alice", false)
  end
end
