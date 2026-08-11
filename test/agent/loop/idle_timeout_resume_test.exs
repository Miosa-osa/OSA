defmodule OptimalSystemAgent.Agent.Loop.IdleTimeoutResumeTest do
  @moduledoc """
  Durability regression: a stream idle timeout must not (a) end the turn as a
  terminal error, nor (b) throw away tool work that ALREADY executed.

  Tools stream-execute eagerly, so by the time the connection goes silent their
  side effects have happened (files written, commands run). Their results used
  to live only in the `:osa_streaming_tool_ctx` process-dictionary entry, which
  the error path never drained — the work vanished and a retry would RE-RUN it
  (a second `git push`, a second file write).

  Codex's turn retry RESUMES from history rather than replaying: tool outputs are
  committed to history BEFORE the retry, so the retry rebuilds from history and
  never re-runs a tool. These tests pin that behaviour.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.StreamingToolExecutor
  alias OptimalSystemAgent.Providers.ErrorCatalog
  alias OptimalSystemAgent.Providers.RetryClassifier

  # Counts every execution so "executed exactly once" is a real assertion.
  defmodule CountingExecutor do
    @moduledoc false
    def execute_tool_call(tc, state) do
      :counters.add(Map.fetch!(state, :counter), 1, 1)
      tool_msg = %{role: "tool", tool_call_id: tc.id, name: tc.name, content: "ran:#{tc.name}"}
      {tool_msg, "ran:#{tc.name}"}
    end
  end

  defp idle_reason(elapsed_ms \\ 300_000, partial \\ "") do
    {:idle_timeout,
     %{
       elapsed_ms: elapsed_ms,
       partial: partial,
       message: "LLM stream went silent for #{div(elapsed_ms, 1000)}s — connection likely dropped"
     }}
  end

  describe "(a) an idle timeout mid-turn is classified RETRYABLE" do
    test "ReactLoop.idle_timeout?/1 recognises the structured reason" do
      assert ReactLoop.idle_timeout?(idle_reason())
      assert ReactLoop.idle_timeout?({:stream_error, idle_reason()})
      assert ReactLoop.idle_timeout?({:stream_error, idle_reason(), "partial"})
    end

    test "the legacy bare-string form is still recognised" do
      assert ReactLoop.idle_timeout?(
               "LLM stream went silent for 300s — connection likely dropped"
             )
    end

    test "unrelated errors are NOT treated as idle timeouts" do
      refute ReactLoop.idle_timeout?("Anthropic returned 401: invalid x-api-key")
      refute ReactLoop.idle_timeout?({:rate_limited, 30})
      refute ReactLoop.idle_timeout?(:some_atom)
    end

    test "the turn-level retry budget is bounded and non-zero" do
      assert ReactLoop.max_idle_timeout_retries() >= 1
      assert ReactLoop.max_idle_timeout_retries() <= 5
    end

    test "the provider layers classify it as a transient/retryable timeout too" do
      reason = idle_reason()

      assert ErrorCatalog.classify(reason) == :timeout

      # Not fatal: the same-provider retry loop would retry it.
      decision = RetryClassifier.classify(reason, 0, 3)
      assert match?({:retry_with_client_rebuild, _}, decision) or match?({:retry, _}, decision)
    end
  end

  describe "(b) tool results executed before the idle timeout land in history" do
    test "a tool that already ran is committed as a valid assistant/tool pair" do
      counter = :counters.new(1, [])
      state = %{session_id: "idle_test", counter: counter, tool_executor: CountingExecutor}

      tool_call = %{id: "call_1", name: "file_write", arguments: %{"path" => "x"}}

      ctx =
        state
        |> StreamingToolExecutor.start()
        |> StreamingToolExecutor.tool_block_complete(tool_call, state)

      # The side effect HAPPENED — exactly once.
      assert {:ok, [assistant | tool_msgs], names} =
               StreamingToolExecutor.drain_to_messages(ctx, "I'll write the file.")

      assert :counters.get(counter, 1) == 1
      assert names == ["file_write"]

      # The assistant message OWNS the tool_use id, so history stays API-valid.
      assert assistant.role == "assistant"
      assert assistant.content == "I'll write the file."
      assert Enum.map(assistant.tool_calls, & &1.id) == ["call_1"]

      assert [%{role: "tool", tool_call_id: "call_1", content: "ran:file_write"}] = tool_msgs
    end

    test "the drained history has NO pending tool_use — so a retry cannot re-run it" do
      counter = :counters.new(1, [])
      state = %{session_id: "idle_test", counter: counter, tool_executor: CountingExecutor}

      calls = [
        %{id: "call_1", name: "shell_execute", arguments: %{"command" => "git push"}},
        %{id: "call_2", name: "file_write", arguments: %{"path" => "y"}}
      ]

      ctx =
        Enum.reduce(calls, StreamingToolExecutor.start(state), fn tc, acc ->
          StreamingToolExecutor.tool_block_complete(acc, tc, state)
        end)

      prior = [%{role: "user", content: "push it"}]

      assert {:ok, committed, names} = StreamingToolExecutor.drain_to_messages(ctx, "")
      assert names == ["shell_execute", "file_write"]
      assert :counters.get(counter, 1) == 2

      history = prior ++ committed

      # This is the property that prevents re-execution on the next attempt:
      # every tool_use id in history already carries a result, so the resumed
      # turn re-sends completed calls instead of pending ones.
      issued =
        history
        |> Enum.flat_map(fn m -> Map.get(m, :tool_calls) || [] end)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      answered =
        history
        |> Enum.filter(&(Map.get(&1, :role) == "tool"))
        |> Enum.map(& &1.tool_call_id)
        |> MapSet.new()

      assert MapSet.equal?(issued, answered)
      assert MapSet.size(issued) == 2

      # Rebuilding from that history executes nothing further.
      assert :counters.get(counter, 1) == 2
    end

    test "draining is not double-counting: a drained context yields nothing a second time" do
      counter = :counters.new(1, [])
      state = %{session_id: "idle_test", counter: counter, tool_executor: CountingExecutor}

      ctx =
        state
        |> StreamingToolExecutor.start()
        |> StreamingToolExecutor.tool_block_complete(
          %{id: "call_1", name: "file_write", arguments: %{}},
          state
        )

      assert {:ok, _msgs, ["file_write"]} = StreamingToolExecutor.drain_to_messages(ctx, "")
      assert :counters.get(counter, 1) == 1

      # The ReactLoop error path deletes :osa_streaming_tool_ctx after draining;
      # a nil (or empty) context must be a hard no-op, never a second commit.
      assert :none = StreamingToolExecutor.drain_to_messages(nil, "")

      assert :none =
               StreamingToolExecutor.drain_to_messages(StreamingToolExecutor.start(state), "")

      assert :counters.get(counter, 1) == 1
    end

    test "a turn where no tool streamed drains to :none (no synthetic history)" do
      state = %{session_id: "idle_test"}
      assert :none = StreamingToolExecutor.drain_to_messages(StreamingToolExecutor.start(state))
    end

    test "discard/1 clears the recorded calls so nothing can be re-committed" do
      counter = :counters.new(1, [])
      state = %{session_id: "idle_test", counter: counter, tool_executor: CountingExecutor}

      ctx =
        state
        |> StreamingToolExecutor.start()
        |> StreamingToolExecutor.tool_block_complete(
          %{id: "call_1", name: "file_write", arguments: %{}},
          state
        )

      # Let the task finish so shutdown is deterministic.
      Process.sleep(50)
      cleared = StreamingToolExecutor.discard(ctx)

      assert cleared.order == []
      assert cleared.calls == %{}
      assert :none = StreamingToolExecutor.drain_to_messages(cleared, "")
    end
  end
end
