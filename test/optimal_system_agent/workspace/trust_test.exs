defmodule OptimalSystemAgent.Workspace.TrustTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Workspace.Trust

  setup do
    home = Path.join(System.tmp_dir!(), "osa_trust_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "accept persists, parent-walk inherits, forget reverts", %{home: home} do
    ws = Path.join(home, "repo")
    sub = Path.join(ws, "nested/deep")
    File.mkdir_p!(sub)

    refute Trust.trusted?(ws)
    assert :ok = Trust.accept(ws)
    assert Trust.trusted?(ws)
    # Parent-directory inheritance: subdir of a trusted folder is trusted.
    assert Trust.trusted?(sub)

    Trust.forget(ws)
    refute Trust.trusted?(ws)
  end

  test "home dir gets session-only trust (never persisted)", %{home: home} do
    home_dir = Path.expand(System.user_home!())
    Trust.forget(home_dir)
    assert :ok = Trust.accept(home_dir)
    assert Trust.trusted?(home_dir)

    store = Path.join(home, "trusted_workspaces.json")
    refute File.exists?(store) and String.contains?(File.read!(store), home_dir)
    Trust.forget(home_dir)
  end

  test "risk enumeration flags hooks, env, bash rules and mcp servers", %{home: home} do
    ws = Path.join(home, "risky")
    File.mkdir_p!(Path.join(ws, ".osa"))

    File.write!(
      Path.join(ws, ".osa/settings.json"),
      Jason.encode!(%{
        "hooks" => %{"PreToolUse" => []},
        "env" => %{"PATH" => "/evil"},
        "permissions" => %{"allow" => ["Bash(rm:*)"]}
      })
    )

    File.write!(Path.join(ws, ".mcp.json"), Jason.encode!(%{"mcpServers" => %{"evil" => %{}}}))

    kinds = Trust.risks(ws) |> Enum.map(& &1.kind)
    assert :hooks in kinds
    assert :env in kinds
    assert :bash_allow in kinds
    assert :mcp in kinds

    # Clean/empty workspace enumerates no risks and never raises.
    clean = Path.join(home, "clean")
    File.mkdir_p!(clean)
    assert Trust.risks(clean) == []
  end
end
