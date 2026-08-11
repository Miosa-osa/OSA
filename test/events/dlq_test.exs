defmodule OptimalSystemAgent.Events.DLQTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.DLQ

  # Helper to force an entry to be retry-eligible by setting next_retry_at to the past
  defp force_ready_for_retry do
    past = System.monotonic_time(:millisecond) - 10_000
    [{id, entry}] = :ets.tab2list(:osa_dlq)
    :ets.insert(:osa_dlq, {id, %{entry | next_retry_at: past}})
  end

  defp force_ready_for_retry_with_retries(retries) do
    past = System.monotonic_time(:millisecond) - 10_000
    [{id, entry}] = :ets.tab2list(:osa_dlq)
    :ets.insert(:osa_dlq, {id, %{entry | next_retry_at: past, retries: retries}})
  end

  setup do
    case GenServer.whereis(DLQ) do
      nil ->
        {:ok, pid} = DLQ.start_link([])

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

      _pid ->
        try do
          :ets.delete_all_objects(:osa_dlq)
        rescue
          ArgumentError -> :ok
        end
    end

    try do
      :ets.delete_all_objects(:osa_dlq_dead)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "enqueue/4" do
    test "adds entry to the DLQ" do
      handler = fn _payload -> :ok end
      assert :ok = DLQ.enqueue(:tool_call, %{tool: "test"}, handler, "boom")
      assert DLQ.depth() == 1
    end

    test "multiple entries increment depth" do
      handler = fn _payload -> :ok end
      DLQ.enqueue(:tool_call, %{a: 1}, handler, "err1")
      DLQ.enqueue(:llm_response, %{b: 2}, handler, "err2")
      DLQ.enqueue(:system_event, %{c: 3}, handler, "err3")
      assert DLQ.depth() == 3
    end
  end

  describe "entries/0" do
    test "returns all DLQ entries" do
      handler = fn _payload -> :ok end
      DLQ.enqueue(:tool_call, %{tool: "grep"}, handler, "timeout")
      entries = DLQ.entries()
      assert length(entries) == 1
      [entry] = entries
      assert entry.event_type == :tool_call
      assert entry.error == "timeout"
      assert entry.retries == 0
    end
  end

  describe "drain/0" do
    test "retries and removes successful entries" do
      handler = fn _payload -> :ok end
      DLQ.enqueue(:tool_call, %{}, handler, "transient")
      force_ready_for_retry()

      {successes, failures} = DLQ.drain()
      assert successes == 1
      assert failures == 0
      assert DLQ.depth() == 0
    end

    test "keeps entries that still fail" do
      handler = fn _payload -> raise "still broken" end
      DLQ.enqueue(:tool_call, %{}, handler, "persistent")
      force_ready_for_retry()

      {successes, failures} = DLQ.drain()
      assert successes == 0
      assert failures == 1
      assert DLQ.depth() == 1

      [updated] = DLQ.entries()
      assert updated.retries == 1
    end

    test "drops entries after max retries" do
      handler = fn _payload -> raise "permanent failure" end
      DLQ.enqueue(:tool_call, %{}, handler, "permanent")
      force_ready_for_retry_with_retries(2)

      {successes, failures} = DLQ.drain()
      assert successes == 0
      assert failures == 1
      assert DLQ.depth() == 0
    end

    test "handles empty DLQ" do
      {successes, failures} = DLQ.drain()
      assert successes == 0
      assert failures == 0
    end
  end

  describe "depth/0" do
    test "returns 0 for empty DLQ" do
      assert DLQ.depth() == 0
    end
  end

  describe "non-retryable errors" do
    # A retry re-`apply`s the original handler, so anything the handler did
    # before failing (writing a file, sending a message, spending budget) is
    # replayed. Errors the classifier already knows are fatal must therefore
    # never be retried.
    setup do
      test_pid = self()
      handler = fn payload -> send(test_pid, {:handler_ran, payload}) end
      {:ok, handler: handler}
    end

    test "a permission error is never re-applied", %{handler: handler} do
      DLQ.enqueue(:tool_call, %{path: "/etc/shadow"}, handler, "permission denied: /etc/shadow")

      # Not queued for retry at all.
      assert DLQ.depth() == 0

      assert [dead] = DLQ.dead_entries()
      assert dead.event_type == :tool_call
      assert dead.dead_reason == :permission_denied
      assert dead.error == "permission denied: /etc/shadow"

      assert {0, 0} = DLQ.drain()
      refute_received {:handler_ran, _}
    end

    test "a budget error is never re-applied", %{handler: handler} do
      DLQ.enqueue(:llm_request, %{}, handler, "budget exceeded for session")

      assert DLQ.depth() == 0
      assert [dead] = DLQ.dead_entries()
      assert dead.dead_reason == :budget_exceeded

      DLQ.drain()
      refute_received {:handler_ran, _}
    end

    test "an auth error is never re-applied", %{handler: handler} do
      DLQ.enqueue(:llm_response, %{}, handler, "unauthorized: invalid api key")

      assert DLQ.depth() == 0
      assert [dead] = DLQ.dead_entries()
      assert dead.dead_reason == :llm_error

      DLQ.drain()
      refute_received {:handler_ran, _}
    end

    test "a retryable error still retries — the gate is not blanket-on", %{handler: handler} do
      DLQ.enqueue(:tool_call, %{n: 1}, handler, "connection timed out")

      assert DLQ.depth() == 1
      assert DLQ.dead_entries() == []

      force_ready_for_retry()
      assert {1, 0} = DLQ.drain()
      assert_received {:handler_ran, %{n: 1}}
    end

    test "an entry whose retry fails non-retryably stops after that one attempt" do
      test_pid = self()

      handler = fn payload ->
        send(test_pid, {:handler_ran, payload})
        raise "permission denied while writing"
      end

      # Enqueued under a retryable error, so it does get one attempt.
      DLQ.enqueue(:tool_call, %{n: 2}, handler, "transient")
      assert DLQ.depth() == 1

      force_ready_for_retry()
      DLQ.drain()

      assert_received {:handler_ran, %{n: 2}}

      # ...and is retired instead of being scheduled for two more replays.
      assert DLQ.depth() == 0
      assert [dead] = DLQ.dead_entries()
      assert dead.dead_reason == :permission_denied
      assert dead.error == "permission denied while writing"

      DLQ.drain()
      refute_received {:handler_ran, _}
    end
  end

  describe "exponential backoff" do
    test "backoff increases with retries" do
      handler = fn _payload -> raise "fail" end
      DLQ.enqueue(:tool_call, %{}, handler, "fail")
      force_ready_for_retry()

      DLQ.drain()

      [updated] = DLQ.entries()
      assert updated.next_retry_at > System.monotonic_time(:millisecond)
    end
  end
end
