defmodule OptimalSystemAgent.Remote.PtyBridgeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Remote.PtyBridge

  # Inject a mock transport (send_fn) and output sink (out_fn) that capture into
  # the test process, so the bridge is exercised with no live server.
  setup do
    test = self()
    send_fn = fn frame -> send(test, {:sent, frame}) end
    out_fn = fn data -> send(test, {:out, data}) end

    bridge = PtyBridge.new("sid-1", send_fn: send_fn, out_fn: out_fn, cols: 100, rows: 40)
    {:ok, bridge: bridge}
  end

  test "open/2 emits a pty_open_request with geometry", %{bridge: bridge} do
    PtyBridge.open(bridge, "/bin/bash")

    assert_received {:sent,
                     {:pty_open_request,
                      %{session_id: "sid-1", shell: "/bin/bash", cols: 100, rows: 40}}}
  end

  test "stdin bytes become a pty_input frame", %{bridge: bridge} do
    assert {:cont, _} = PtyBridge.step(bridge, {:stdin, "ls -la\n"})
    assert_received {:sent, {:pty_input, %{session_id: "sid-1", data: "ls -la\n"}}}
  end

  test "output frames are rendered to the sink", %{bridge: bridge} do
    assert {:cont, _} =
             PtyBridge.step(
               bridge,
               {:remote_frame, {:pty_output, %{session_id: "sid-1", data: "hello"}}}
             )

    assert_received {:out, "hello"}
  end

  test "output for a different session is ignored", %{bridge: bridge} do
    assert {:cont, _} =
             PtyBridge.step(
               bridge,
               {:remote_frame, {:pty_output, %{session_id: "other", data: "x"}}}
             )

    refute_received {:out, _}
  end

  test "resize emits a pty_resize frame and updates geometry", %{bridge: bridge} do
    assert {:cont, updated} = PtyBridge.step(bridge, {:resize, 120, 50})
    assert updated.cols == 120
    assert updated.rows == 50
    assert_received {:sent, {:pty_resize, %{session_id: "sid-1", cols: 120, rows: 50}}}
  end

  test "pty_close halts with the exit code", %{bridge: bridge} do
    assert {:halt, 3, _} =
             PtyBridge.step(
               bridge,
               {:remote_frame, {:pty_close, %{session_id: "sid-1", exit_code: 3}}}
             )
  end

  test "pty_error renders and halts non-zero", %{bridge: bridge} do
    assert {:halt, 1, _} =
             PtyBridge.step(
               bridge,
               {:remote_frame, {:pty_error, %{session_id: "sid-1", reason: :shell_not_allowed}}}
             )

    assert_received {:out, msg}
    assert msg =~ "pty error"
  end

  test "local EOF sends pty_close and halts", %{bridge: bridge} do
    assert {:halt, 0, _} = PtyBridge.step(bridge, :eof)
    assert_received {:sent, {:pty_close, %{session_id: "sid-1"}}}
  end

  test "broker close halts", %{bridge: bridge} do
    assert {:halt, 1, _} = PtyBridge.step(bridge, {:remote_frame, {:__closed__, 1006}})
    assert_received {:out, msg}
    assert msg =~ "closed"
  end
end
