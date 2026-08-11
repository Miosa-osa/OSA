defmodule OptimalSystemAgent.Monitor.WatchTaskTest do
  @moduledoc """
  The watcher must actually observe the whole window it was asked to watch.

  The last `:poll` timer is clamped to land exactly ON the deadline, so a
  watcher that checks the deadline before sampling never looks at the target
  during its final poll interval — a real change in that window is reported as
  "no change", which is worse than not watching at all.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Monitor.WatchTask

  @moduletag :tmp_dir

  setup do
    ensure_registry(OptimalSystemAgent.Monitor.WatchRegistry)
    ensure_registry(OptimalSystemAgent.SessionRegistry)
    :ok
  end

  defp ensure_registry(name) do
    case Process.whereis(name) do
      nil -> start_supervised!({Registry, keys: :unique, name: name})
      _ -> :ok
    end
  end

  # The watcher injects into its session's `Agent.Loop` via the SessionRegistry,
  # so registering the test process under a session id makes the injection land
  # in our own mailbox as a raw cast.
  defp register_session do
    session_id = "watch-task-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(OptimalSystemAgent.SessionRegistry, session_id, nil)
    session_id
  end

  test "a change during the final poll window is still reported", %{tmp_dir: tmp} do
    path = Path.join(tmp, "watched.txt")
    File.write!(path, "before")

    session_id = register_session()

    # One second of watching, one poll: the only timer lands exactly on the
    # deadline, so this change is visible only to a deadline sample.
    input = %{
      "kind" => "file",
      "target" => path,
      "mode" => "once",
      "duration_seconds" => 1,
      "poll_interval_ms" => 1_000
    }

    {:ok, pid} =
      WatchTask.start_link(
        id: "watch-#{System.unique_integer([:positive])}",
        input: input,
        session_id: session_id
      )

    ref = Process.monitor(pid)

    Process.sleep(400)
    File.write!(path, "after — this changed inside the last poll window")

    assert_receive {:"$gen_cast", {:inject_agent_result, body}}, 3_000
    assert body =~ "change on file:#{path}"
    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
  end

  test "an unchanged target still times out without firing", %{tmp_dir: tmp} do
    path = Path.join(tmp, "quiet.txt")
    File.write!(path, "steady")

    session_id = register_session()

    input = %{
      "kind" => "file",
      "target" => path,
      "mode" => "once",
      "duration_seconds" => 1,
      "poll_interval_ms" => 300
    }

    {:ok, pid} =
      WatchTask.start_link(
        id: "watch-#{System.unique_integer([:positive])}",
        input: input,
        session_id: session_id
      )

    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
    refute_received {:"$gen_cast", {:inject_agent_result, _}}
  end
end
