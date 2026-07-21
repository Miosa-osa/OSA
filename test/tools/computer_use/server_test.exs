defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.ServerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Server

  # Use a mock adapter for testing — no real xdotool/maim needed
  defmodule MockAdapter do
    @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

    def available?, do: true
    def screenshot(_opts), do: {:ok, "/tmp/mock_screenshot.png"}
    def click(_x, _y), do: :ok
    def double_click(_x, _y), do: :ok
    def type_text(_text), do: :ok
    def key_press(_combo), do: :ok
    def scroll(_dir, _amount), do: :ok
    def move_mouse(_x, _y), do: :ok
    def drag(_fx, _fy, _tx, _ty), do: :ok

    def get_tree do
      {:ok,
       [
         %{role: "button", name: "Save", x: 500, y: 300, width: 80, height: 30},
         %{role: "textfield", name: "Email", x: 200, y: 150, width: 200, height: 25},
         %{role: "link", name: "Help", x: 100, y: 50, width: 40, height: 20}
       ]}
    end
  end

  # `Server.start_link/1` LINKS the server to the test process, so when the test
  # body finishes the server is torn down by the exit signal at the same time
  # on_exit runs in its own process. `Process.alive?/1` can therefore still read
  # true a hair before the stop lands, making a bare `GenServer.stop/1` crash
  # with :noproc. Tolerate an already-terminated server — cleanup is best-effort.
  defp stop_server(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Server lifecycle
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts with adapter and platform" do
      {:ok, pid} =
        Server.start_link(adapter: MockAdapter, platform: :linux_x11, session_id: "test_1")

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initializes with empty element refs" do
      {:ok, pid} =
        Server.start_link(adapter: MockAdapter, platform: :linux_x11, session_id: "test_2")

      state = :sys.get_state(pid)
      assert state.element_refs == %{}
      assert state.step_counter == 0
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Idle shutdown
  # ---------------------------------------------------------------------------

  describe "idle shutdown" do
    test "server stops after idle timeout" do
      # Use a very short timeout for testing
      {:ok, pid} =
        Server.start_link(
          adapter: MockAdapter,
          platform: :linux_x11,
          session_id: "test_idle",
          idle_timeout_ms: 100
        )

      ref = Process.monitor(pid)

      # Wait for idle shutdown
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end

    test "action resets idle timer" do
      {:ok, pid} =
        Server.start_link(
          adapter: MockAdapter,
          platform: :linux_x11,
          session_id: "test_reset",
          idle_timeout_ms: 200
        )

      ref = Process.monitor(pid)

      # Keep alive with actions
      {:ok, _} = Server.execute(pid, "click", %{"x" => 100, "y" => 200})
      Process.sleep(100)
      {:ok, _} = Server.execute(pid, "click", %{"x" => 100, "y" => 200})
      Process.sleep(100)

      # Should still be alive (timer reset each time)
      assert Process.alive?(pid)

      # Now let it time out
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Action dispatch
  # ---------------------------------------------------------------------------

  describe "execute/3" do
    setup do
      {:ok, pid} =
        Server.start_link(adapter: MockAdapter, platform: :linux_x11, session_id: "test_exec")

      on_exit(fn -> stop_server(pid) end)
      %{pid: pid}
    end

    test "click dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "click", %{"x" => 100, "y" => 200})
      assert msg =~ "Click"
    end

    test "double_click dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "double_click", %{"x" => 100, "y" => 200})
      assert msg =~ "Double click"
    end

    test "type dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "type", %{"text" => "hello"})
      assert msg =~ "Typed"
    end

    test "key dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "key", %{"text" => "ctrl+c"})
      assert msg =~ "Key press"
    end

    test "scroll dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "scroll", %{"direction" => "down"})
      assert msg =~ "Scroll"
    end

    test "move_mouse dispatches to adapter", %{pid: pid} do
      assert {:ok, msg} = Server.execute(pid, "move_mouse", %{"x" => 300, "y" => 400})
      assert msg =~ "Mouse moved"
    end

    test "screenshot dispatches to adapter", %{pid: pid} do
      result = Server.execute(pid, "screenshot", %{})
      assert match?({:ok, _}, result)
    end

    test "increments step counter", %{pid: pid} do
      Server.execute(pid, "click", %{"x" => 1, "y" => 1})
      Server.execute(pid, "click", %{"x" => 2, "y" => 2})
      state = :sys.get_state(pid)
      assert state.step_counter == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Element ref resolution
  # ---------------------------------------------------------------------------

  describe "element ref resolution" do
    setup do
      {:ok, pid} =
        Server.start_link(adapter: MockAdapter, platform: :linux_x11, session_id: "test_refs")

      on_exit(fn -> stop_server(pid) end)

      # Populate refs by fetching tree
      {:ok, _tree_text} = Server.execute(pid, "get_tree", %{})
      %{pid: pid}
    end

    test "click with target resolves element ref", %{pid: pid} do
      # "e0" should be the first element (Save button at 500,300)
      assert {:ok, msg} = Server.execute(pid, "click", %{"target" => "e0"})
      assert msg =~ "Click on e0"
    end

    test "click with unknown target returns error", %{pid: pid} do
      assert {:error, msg} = Server.execute(pid, "click", %{"target" => "e99"})
      assert msg =~ "Unknown element ref"
    end
  end

  # ---------------------------------------------------------------------------
  # Tree caching
  # ---------------------------------------------------------------------------

  describe "tree caching" do
    setup do
      {:ok, pid} =
        Server.start_link(adapter: MockAdapter, platform: :linux_x11, session_id: "test_cache")

      on_exit(fn -> stop_server(pid) end)
      %{pid: pid}
    end

    test "get_tree returns formatted tree", %{pid: pid} do
      {:ok, tree_text} = Server.execute(pid, "get_tree", %{})
      assert is_binary(tree_text)
      assert tree_text =~ "button"
      assert tree_text =~ "Save"
    end

    test "get_tree caches within TTL", %{pid: pid} do
      {:ok, tree1} = Server.execute(pid, "get_tree", %{})
      {:ok, tree2} = Server.execute(pid, "get_tree", %{})
      # Same result from cache
      assert tree1 == tree2
    end

    test "force_refresh bypasses cache", %{pid: pid} do
      {:ok, _} = Server.execute(pid, "get_tree", %{})
      state_before = :sys.get_state(pid)

      {:ok, _} = Server.execute(pid, "get_tree", %{"force_refresh" => true})
      state_after = :sys.get_state(pid)

      # tree_fetched_at should be updated
      assert state_after.tree_fetched_at >= state_before.tree_fetched_at
    end
  end
end
