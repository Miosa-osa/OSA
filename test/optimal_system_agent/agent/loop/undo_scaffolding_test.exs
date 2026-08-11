defmodule OptimalSystemAgent.Agent.Loop.UndoScaffoldingTest do
  @moduledoc """
  D6 — `/undo` walked to the last message with `role == "user"`, but OSA writes
  user-role SCAFFOLDING the user never typed:

    * `ReactLoop.finalize_interrupt/2`'s `[Request interrupted by user]` marker
    * `Loop.inject_agent_result/2`'s delegation-result injection

  So `/undo` immediately after an interrupt (or after a teammate reported back)
  dropped ONLY the scaffolding: nothing the user could see changed, yet it
  reported `dropped: 1`. The user pressed it again — and lost a real turn.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  defp sid,
    do: "undo-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  setup do
    # Loop.start_link/1 links to us and traps exits itself; a shutdown exit
    # reaching the test process would fail an otherwise-passing test.
    Process.flag(:trap_exit, true)
    :ok
  end

  defp start_loop(messages) do
    id = sid()

    {:ok, pid} =
      Loop.start_link(
        session_id: id,
        user_id: "test",
        channel: :internal,
        messages: messages
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {id, pid}
  end

  @real_user %{role: "user", content: "refactor the parser"}
  @real_reply %{role: "assistant", content: "here is the refactor"}

  describe "/undo after an interrupt" do
    test "removes the REAL exchange, not just the interrupt marker" do
      marker = %{role: "user", content: List.first(ReactLoop.interrupt_markers())}

      {_id, pid} = start_loop([@real_user, @real_reply, marker])

      assert {:ok, stats} = GenServer.call(pid, :undo)

      # All three go: the user's turn, its reply, and the marker appended after it.
      assert stats.dropped == 3
      assert stats.messages_after == 0
      assert GenServer.call(pid, :get_messages) == []
    end

    test "the tool-use interrupt marker is scaffolding too" do
      marker = %{role: "user", content: List.last(ReactLoop.interrupt_markers())}

      {_id, pid} = start_loop([@real_user, @real_reply, marker])

      assert {:ok, %{dropped: 3, messages_after: 0}} = GenServer.call(pid, :undo)
    end

    test "an earlier real turn survives a single /undo" do
      marker = %{role: "user", content: List.first(ReactLoop.interrupt_markers())}
      first = %{role: "user", content: "first question"}
      first_reply = %{role: "assistant", content: "first answer"}

      {_id, pid} = start_loop([first, first_reply, @real_user, @real_reply, marker])

      assert {:ok, %{dropped: 3, messages_after: 2}} = GenServer.call(pid, :undo)
      assert [^first, ^first_reply] = GenServer.call(pid, :get_messages)
    end
  end

  describe "/undo after a delegation result" do
    test "removes the real exchange, not just the injected agent result" do
      {id, pid} = start_loop([@real_user, @real_reply])

      Loop.inject_agent_result(id, "teammate @backend finished: done")
      # cast — make sure it landed before we undo
      assert length(GenServer.call(pid, :get_messages)) == 3

      assert {:ok, %{dropped: 3, messages_after: 0}} = GenServer.call(pid, :undo)
    end
  end

  describe "ordinary /undo is unchanged" do
    test "a plain user turn plus reply is dropped exactly once" do
      {_id, pid} = start_loop([@real_user, @real_reply])

      assert {:ok, %{dropped: 2, messages_after: 0}} = GenServer.call(pid, :undo)
    end

    test "history with no real user turn is left alone" do
      {_id, pid} = start_loop([%{role: "assistant", content: "hello"}])

      assert {:ok, %{dropped: 0, messages_after: 1}} = GenServer.call(pid, :undo)
    end
  end
end
