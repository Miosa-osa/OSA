defmodule OptimalSystemAgent.Monitor.WatchTaskFramesTest do
  @moduledoc """
  Regression test — the `monitor` tool's lifecycle must reach the TUI's agents
  tree as three frames (`monitor_started`, `monitor_event`, `monitor_done`),
  each carrying the fixed `id`/`label`/`state`/`parent_agent_id` shape the tree
  renders a node from, over the SAME `Events.Bus` → `Events.TuiForwarder` →
  `osa:session:<id>` transport `BackgroundNotifier`/`Fleet` already use for
  subagent nodes (no new transport introduced).

  Asserts directly on `Bus.emit(:system_event, ...)` — the same call
  `Events.TuiForwarder` itself listens on — rather than on the PubSub bridge,
  so this locks in the producer's contract independent of the forwarder's
  allowlist (covered separately by reading `tui_forwarder.ex`'s
  `@forward_events`).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Monitor.WatchTask

  @moduletag :tmp_dir

  setup do
    ensure_registry(OptimalSystemAgent.Monitor.WatchRegistry)
    ensure_registry(OptimalSystemAgent.SessionRegistry)

    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        data = payload[:data] || %{}

        if data[:event] in [:monitor_started, :monitor_event, :monitor_done] do
          send(test_pid, {:frame, data})
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
    :ok
  end

  defp ensure_registry(name) do
    case Process.whereis(name) do
      nil -> start_supervised!({Registry, keys: :unique, name: name})
      _ -> :ok
    end
  end

  defp register_session(session_id) do
    {:ok, _} = Registry.register(OptimalSystemAgent.SessionRegistry, session_id, nil)
    session_id
  end

  defp assert_frame(event, watch_id, label, state, parent_agent_id) do
    assert_receive {:frame, %{event: ^event} = data}, 3_000

    assert data.id == watch_id
    assert data.label == label
    assert data.state == state
    assert data.parent_agent_id == parent_agent_id
    data
  end

  test "a monitor started by the main/root session emits all three frames with no parent",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "watched.txt")
    File.write!(path, "before")

    # A plain session id — no "agent:" prefix — is the main/root session.
    session_id = register_session("root-#{System.unique_integer([:positive])}")
    watch_id = "watch-#{System.unique_integer([:positive])}"
    label = "file:#{path}"

    input = %{
      "kind" => "file",
      "target" => path,
      "mode" => "once",
      "duration_seconds" => 2,
      "poll_interval_ms" => 100
    }

    {:ok, pid} = WatchTask.start_link(id: watch_id, input: input, session_id: session_id)
    ref = Process.monitor(pid)

    assert_frame(:monitor_started, watch_id, label, "running", nil)

    File.write!(path, "after")

    frame = assert_frame(:monitor_event, watch_id, label, "running", nil)
    assert frame.fire == 1

    assert_frame(:monitor_done, watch_id, label, "done", nil)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
  end

  test "a monitor started by a subagent carries parent_agent_id, and a manual stop emits monitor_done",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "watched.txt")
    File.write!(path, "steady")

    subagent_id = "agent:root-#{System.unique_integer([:positive])}:researcher"
    session_id = register_session(subagent_id)
    watch_id = "watch-#{System.unique_integer([:positive])}"
    label = "file:#{path}"

    input = %{
      "kind" => "file",
      "target" => path,
      "mode" => "repeat",
      "duration_seconds" => 60,
      "poll_interval_ms" => 100
    }

    {:ok, pid} = WatchTask.start_link(id: watch_id, input: input, session_id: session_id)
    ref = Process.monitor(pid)

    assert_frame(:monitor_started, watch_id, label, "running", subagent_id)

    WatchTask.stop(pid)

    assert_frame(:monitor_done, watch_id, label, "stopped", subagent_id)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
  end

  test "a monitor that times out without firing emits monitor_done with state timeout",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "quiet.txt")
    File.write!(path, "steady")

    session_id = register_session("root-#{System.unique_integer([:positive])}")
    watch_id = "watch-#{System.unique_integer([:positive])}"
    label = "file:#{path}"

    input = %{
      "kind" => "file",
      "target" => path,
      "mode" => "once",
      "duration_seconds" => 1,
      "poll_interval_ms" => 300
    }

    {:ok, pid} = WatchTask.start_link(id: watch_id, input: input, session_id: session_id)
    ref = Process.monitor(pid)

    assert_frame(:monitor_started, watch_id, label, "running", nil)
    assert_frame(:monitor_done, watch_id, label, "timeout", nil)
    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
    refute_received {:frame, %{event: :monitor_event}}
  end
end
