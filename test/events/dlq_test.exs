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
