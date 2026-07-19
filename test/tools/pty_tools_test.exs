defmodule OptimalSystemAgent.Tools.Builtins.PtyToolsTest do
  @moduledoc """
  Exercises the model-facing `pty_*` tool surface: registration, the pty_start
  permission gate, and a full start→send→wait→read→stop round-trip through the
  tool `execute/1` entry points. Skips if this host has no pty allocator.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.Pty.Session
  alias OptimalSystemAgent.Tools.Builtins.Pty.{PtyRead, PtySend, PtyStart, PtyStop, PtyWait}
  alias OptimalSystemAgent.Tools.Registry

  setup_all do
    case Session.allocator() do
      {:ok, _, _} -> :ok
      _ -> {:skip, "no PTY allocator (script) on this host"}
    end
  end

  setup do
    on_exit(fn ->
      for %{id: id} <- OptimalSystemAgent.Shell.Pty.Manager.list() do
        OptimalSystemAgent.Shell.Pty.Manager.stop(id)
      end
    end)

    :ok
  end

  test "all five pty tools are registered and visible to the model" do
    names = Registry.list_tools_direct() |> Enum.map(& &1.name) |> MapSet.new()

    for tool <- ~w(pty_start pty_send pty_read pty_wait pty_stop) do
      assert MapSet.member?(names, tool), "expected #{tool} to be registered"
    end
  end

  test "pty_start hard-blocks a catastrophic command (permission gate)" do
    ctx = OptimalSystemAgent.Tools.UseContext.new(%{})
    assert {:deny, reason} = PtyStart.check_permissions(%{"command" => "rm -rf /"}, ctx)
    assert reason =~ "Blocked"
  end

  test "pty_start allows a benign command" do
    ctx = OptimalSystemAgent.Tools.UseContext.new(%{})
    assert {:allow, _} = PtyStart.check_permissions(%{"command" => "python3"}, ctx)
  end

  test "full start → send → wait → read → stop round-trip via the tools" do
    assert {:ok, msg} = PtyStart.execute(%{"command" => "cat", "name" => "toolcat"})
    assert msg =~ "Started PTY session"

    assert {:ok, _} = PtySend.execute(%{"session" => "toolcat", "keys" => "tool-roundtrip<CR>"})

    assert {:ok, wait_out} =
             PtyWait.execute(%{
               "session" => "toolcat",
               "condition" => %{"text" => "tool-roundtrip"},
               "timeout_ms" => 5_000
             })

    assert wait_out =~ "MATCHED"

    assert {:ok, screen} = PtyRead.execute(%{"session" => "toolcat", "mode" => "screen"})
    assert screen =~ "tool-roundtrip"

    assert {:ok, status} = PtyRead.execute(%{"session" => "toolcat", "mode" => "status"})
    assert status =~ "alive"

    assert {:ok, stop_msg} = PtyStop.execute(%{"session" => "toolcat"})
    assert stop_msg =~ "Stopped"
  end

  test "pty tools give a clear error for an unknown session" do
    assert {:error, reason} = PtySend.execute(%{"session" => "nope", "keys" => "x"})
    assert reason =~ "No such pty session"
  end
end
