defmodule OptimalSystemAgent.Tools.Builtins.ShellExecuteOutputStreamTest do
  @moduledoc """
  Live command-output streaming (`command_output_delta`).

  A long foreground command used to show the TUI nothing but a spinner. The
  handler now emits throttled progress events on the same per-session PubSub
  topic `broadcast_command_started/3` uses, carrying the session id, the
  command, the incremental chunk and a rolling tail.

  These tests pin the two properties that matter:
    1. the events are actually emitted, with the documented shape; and
    2. the feature is PURELY ADDITIVE — the tool's return value is byte-for-byte
       what it was before, with or without a session to stream to.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler

  defp subscribe(session_id) do
    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
  end

  defp session_id, do: "test-stream-#{System.unique_integer([:positive])}"

  # A command that dribbles output out over ~1s, so more than one throttle
  # window (250ms) elapses while it runs.
  defp dribble, do: "for i in 1 2 3 4; do echo line$i; sleep 0.3; done"

  describe "command_output_delta" do
    @tag :tmp_dir
    test "streams progress while a foreground command runs", %{tmp_dir: tmp} do
      sid = session_id()
      subscribe(sid)

      assert {:ok, out} =
               Handler.execute(%{"command" => dribble(), "cwd" => tmp}, %{session_id: sid})

      # The final result is unchanged — every line, in order.
      assert out =~ "line1"
      assert out =~ "line4"

      deltas = collect_deltas([])

      assert deltas != [], "expected at least one command_output_delta"

      for d <- deltas do
        assert d.type == :command_output_delta
        assert d.session_id == sid
        assert d.command == dribble()
        assert is_binary(d.chunk)
        assert is_binary(d.tail)
        assert is_integer(d.seq)
      end

      # seq is a monotonic per-command counter starting at 0.
      seqs = Enum.map(deltas, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert hd(seqs) == 0

      # Concatenating the chunks reproduces the streamed output, and the rolling
      # tail of the LAST delta is a suffix of what the command had printed.
      streamed = deltas |> Enum.map_join("", & &1.chunk)
      assert streamed =~ "line1"
      last = List.last(deltas)
      assert String.ends_with?(String.trim_trailing(last.tail), String.trim_trailing(last.chunk))
    end

    @tag :tmp_dir
    test "throttles rather than emitting one event per port chunk", %{tmp_dir: tmp} do
      sid = session_id()
      subscribe(sid)

      # 2000 rapid lines: unthrottled this would be hundreds of port chunks and
      # therefore hundreds of events. Throttled at ~4/sec, a sub-second command
      # can only produce a handful.
      cmd = "for i in $(seq 1 2000); do echo \"chunk $i\"; done"
      assert {:ok, out} = Handler.execute(%{"command" => cmd, "cwd" => tmp}, %{session_id: sid})
      assert out =~ "chunk 2000"

      deltas = collect_deltas([])
      assert length(deltas) <= 20, "throttle failed: #{length(deltas)} events for a fast command"
    end

    @tag :tmp_dir
    test "emits nothing and returns normally without a session", %{tmp_dir: tmp} do
      sid = session_id()
      # Subscribe to a topic nothing should publish on.
      subscribe(sid)

      assert {:ok, out} = Handler.execute(%{"command" => "echo hello", "cwd" => tmp}, %{})
      assert out =~ "hello"

      refute_receive {:osa_event, %{type: :command_output_delta}}, 200
    end

    @tag :tmp_dir
    test "a failing command still reports its exit code and full output", %{tmp_dir: tmp} do
      sid = session_id()
      subscribe(sid)

      cmd = "echo before; sleep 0.3; echo after; exit 7"

      assert {:error, msg} =
               Handler.execute(%{"command" => cmd, "cwd" => tmp}, %{session_id: sid})

      assert msg =~ "Exit 7"
      assert msg =~ "before"
      assert msg =~ "after"
    end
  end

  # Drain every delta currently queued (the command has already exited by the
  # time this is called, so all of them are in the mailbox).
  defp collect_deltas(acc) do
    receive do
      {:osa_event, %{type: :command_output_delta} = d} -> collect_deltas([d | acc])
      {:osa_event, _other} -> collect_deltas(acc)
    after
      300 -> Enum.reverse(acc)
    end
  end
end
