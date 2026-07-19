defmodule OptimalSystemAgent.Shell.Pty.ManagerTest do
  @moduledoc """
  End-to-end tests that spawn REAL processes under a real pty on this host.
  Requires util-linux `script` (probed in setup_all; the whole module skips if
  it is absent so CI on a pty-less box stays green).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.Pty.Manager
  alias OptimalSystemAgent.Shell.Pty.Session

  setup_all do
    case Session.allocator() do
      {:ok, _, _} -> :ok
      _ -> {:skip, "no PTY allocator (script) on this host"}
    end
  end

  # Ensure every started session is torn down even if an assertion fails.
  setup do
    on_exit(fn ->
      for %{id: id} <- Manager.list(), do: Manager.stop(id)
    end)

    :ok
  end

  defp start!(cmd, opts \\ []) do
    {:ok, id} = Manager.start(cmd, opts)
    id
  end

  describe "allocator" do
    test "reports a working pty allocator on this box" do
      assert {:ok, exe, wrap} = Session.allocator()
      assert is_binary(exe)
      assert is_function(wrap, 1)
    end
  end

  describe "cat (echo round-trip)" do
    test "typed text is echoed back and visible on the screen" do
      id = start!("cat")

      assert :ok = Manager.send_keys(id, "hello world<CR>")

      assert {:ok, %{matched: true}} =
               Manager.wait(id, {:text, "hello world"}, 5_000)

      assert {:ok, screen} = Manager.screen(id)
      assert screen =~ "hello world"
    end
  end

  describe "interactive prompt" do
    test "responds to a bash read prompt" do
      id = start!(~s(bash -c 'read -p "Name: " n; echo "Hi, $n"'))

      assert {:ok, %{matched: true}} = Manager.wait(id, {:text, "Name:"}, 5_000)

      assert :ok = Manager.send_keys(id, "Alice<CR>")

      assert {:ok, %{matched: true}} = Manager.wait(id, {:text, "Hi, Alice"}, 5_000)
    end
  end

  describe "wait conditions" do
    test "wait-for-text returns as soon as delayed output lands (event-driven)" do
      id = start!(~s(sh -c 'sleep 0.3; echo READY; sleep 30'))

      assert {:ok, outcome} = Manager.wait(id, {:text, "READY"}, 10_000)
      assert outcome.matched
      # Far below the 10s timeout despite the delayed echo.
      assert outcome.elapsed_ms < 5_000
    end

    test "wait-for-regex matches screen text" do
      id = start!(~s(sh -c 'echo exit code 42; sleep 30'))
      assert {:ok, %{matched: true}} = Manager.wait(id, {:regex, ~r/exit code \d+/}, 5_000)
    end

    test "invalid regex errors instead of waiting" do
      id = start!("cat")
      assert {:error, msg} = Manager.wait(id, {:regex, "(unclosed"}, 1_000)
      assert msg =~ "invalid regex"
    end

    test "wait-for-gone matches once the child exits" do
      id = start!(~s(sh -c 'sleep 0.2; exit 0'))

      assert {:ok, outcome} = Manager.wait(id, :gone, 5_000)
      assert outcome.matched
      assert outcome.ended
    end

    test "stable_ms matches only after output quiesces" do
      id = start!("cat")
      assert :ok = Manager.send_keys(id, "quiesce-now<CR>")

      assert {:ok, outcome} = Manager.wait(id, {:stable_ms, 400}, 5_000)
      assert outcome.matched
      # A full uninterrupted window is a lower bound on the elapsed time.
      assert outcome.elapsed_ms >= 400
    end

    test "wait times out when the condition never appears" do
      id = start!("cat")

      assert {:ok, outcome} = Manager.wait(id, {:text, "NEVER_APPEARS_ZZZ"}, 800)
      refute outcome.matched
      refute outcome.ended
      assert outcome.elapsed_ms >= 700
    end
  end

  describe "status and lifecycle" do
    test "status reflects a live session, and stop kills the child" do
      id = start!("cat")

      assert {:ok, status} = Manager.status(id)
      assert status.alive
      os_pid = status.os_pid
      assert is_integer(os_pid)

      assert :ok = Manager.stop(id)
      # The GenServer stops and unregisters — the session is gone.
      Process.sleep(100)
      assert {:error, :not_found} = Manager.status(id)

      # The OS process is really dead (kill -0 fails).
      {_out, code} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
      assert code != 0
    end

    test "stopping an unknown session is a graceful no-op via the tool contract" do
      assert {:error, :not_found} = Manager.stop("pty_does_not_exist")
    end
  end

  describe "named sessions" do
    test "a session is addressable by its friendly name" do
      _id = start!("cat", name: "editor")

      assert :ok = Manager.send_keys("editor", "named-hello<CR>")
      assert {:ok, %{matched: true}} = Manager.wait("editor", {:text, "named-hello"}, 5_000)
    end
  end

  describe "resize" do
    test "resize reshapes the emulator grid and bumps the generation" do
      id = start!("cat")

      assert {:ok, before} = Manager.status(id)
      assert :ok = Manager.resize(id, 100, 30)
      assert {:ok, after_status} = Manager.status(id)

      assert after_status.cols == 100
      assert after_status.rows == 30
      # Generation strictly increases (grid reshape counts as activity).
      assert after_status.generation > before.generation
    end
  end
end
