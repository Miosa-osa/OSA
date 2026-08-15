defmodule OptimalSystemAgent.Agent.Loop.StreamingToolConcurrencyTest do
  @moduledoc """
  The Anthropic streaming path (`providers/anthropic.ex` → `{:tool_use_block, _}`
  → `ReactLoop.drain_streaming_tool_blocks/2` → `StreamingToolExecutor`) is the
  SECOND tool-dispatch site in the loop. It used to spawn every tool call as a
  Task with no concurrency check at all, so a batched Anthropic turn ran two
  `file_edit` calls against one file simultaneously — a silent lost update.

  These tests pin the fixed behaviour: the streaming path makes the SAME
  concurrency decision the orchestrator makes, so unsafe calls serialise while
  safe (read-only) calls still start eagerly and in parallel.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.StreamingToolExecutor
  alias OptimalSystemAgent.Tools.Builtins.FileEdit
  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.UseContext

  # ── Executors ────────────────────────────────────────────────────────

  # Runs the REAL file_edit read-modify-write. Proves the data-loss hazard
  # concretely rather than by proxy.
  defmodule RealEditExecutor do
    @moduledoc false
    def execute_tool_call(tc, _state) do
      ctx = UseContext.empty()
      result = FileEdit.Tool.execute(tc.arguments, ctx)
      body = inspect(result)
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: body}, body}
    end
  end

  # Reports overlap: records the interval each call occupied so a test can
  # assert ordering (serialised) or simultaneity (parallel) deterministically.
  defmodule OverlapExecutor do
    @moduledoc false
    def execute_tool_call(tc, state) do
      pid = Map.fetch!(state, :test_pid)
      send(pid, {:started, tc.id})
      Process.sleep(Map.get(state, :hold_ms, 120))
      send(pid, {:finished, tc.id})
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "ok"}, "ok"}
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────

  defmodule SafeTool do
    @moduledoc false
    def name, do: "conc_safe_tool"
    def concurrency_safe?(_input, _ctx), do: true
  end

  defmodule UnsafeTool do
    @moduledoc false
    def name, do: "conc_unsafe_tool"
    def concurrency_safe?(_input, _ctx), do: false
  end

  setup do
    builtin = :persistent_term.get({Registry, :builtin_tools}, %{})

    :persistent_term.put(
      {Registry, :builtin_tools},
      Map.merge(builtin, %{
        SafeTool.name() => SafeTool,
        UnsafeTool.name() => UnsafeTool
      })
    )

    on_exit(fn -> :persistent_term.put({Registry, :builtin_tools}, builtin) end)

    dir = Path.join(System.tmp_dir!(), "osa_stream_conc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # "test" is exempt from the read-before-edit / drift guards, so the edit
    # under test is the plain read-modify-write and nothing else.
    {:ok, dir: dir, state: %{session_id: "test", tool_executor: RealEditExecutor}}
  end

  defp fire(ctx, calls, state) do
    Enum.reduce(calls, ctx, fn tc, acc ->
      StreamingToolExecutor.tool_block_complete(acc, tc, state)
    end)
  end

  # `assert_receive` SKIPS non-matching messages, so a sequence of them proves
  # nothing about ordering — it passes even when the events interleaved. Drain
  # the mailbox in arrival order and assert on the actual sequence instead.
  defp event_sequence(n) do
    for _ <- 1..n do
      receive do
        {tag, id} -> {tag, id}
      after
        3_000 -> flunk("timed out waiting for tool event #{n}")
      end
    end
  end

  defp edit_call(id, path, old, new) do
    %{
      id: id,
      name: "file_edit",
      arguments: %{"path" => path, "old_string" => old, "new_string" => new}
    }
  end

  # ── The racing case ──────────────────────────────────────────────────

  describe "two mutating calls on one path" do
    test "both edits land — neither is lost to a concurrent read-modify-write",
         %{dir: dir, state: state} do
      path = Path.join(dir, "target.txt")

      # A body big enough that `File.read` → `Matcher.replace` → `File.write`
      # is not instantaneous: this is the window a concurrent second edit reads
      # stale content in. With the unguarded dispatch the later write clobbers
      # the earlier one and one marker never appears in the file.
      filler = String.duplicate("padding line for the match scan\n", 40_000)
      File.write!(path, "ALPHA\n" <> filler <> "BETA\n")

      ctx =
        StreamingToolExecutor.start(state)
        |> fire(
          [
            edit_call("e1", path, "ALPHA", "ALPHA_EDITED"),
            edit_call("e2", path, "BETA", "BETA_EDITED")
          ],
          state
        )

      _ = StreamingToolExecutor.collect_results(ctx)

      final = File.read!(path)
      assert final =~ "ALPHA_EDITED", "first edit was lost (clobbered by the second)"
      assert final =~ "BETA_EDITED", "second edit was lost (clobbered by the first)"
    end

    test "the two edits do not overlap in time", %{dir: dir} do
      path = Path.join(dir, "ordering.txt")
      File.write!(path, "x")
      state = %{session_id: "test", tool_executor: OverlapExecutor, test_pid: self()}

      ctx =
        StreamingToolExecutor.start(state)
        |> fire(
          [
            edit_call("e1", path, "a", "b"),
            edit_call("e2", path, "c", "d")
          ],
          state
        )

      _ = StreamingToolExecutor.collect_results(ctx)

      # Serialised: e1 must FINISH before e2 STARTS. Asserted on the exact
      # arrival sequence, not on four independent `assert_receive`s.
      assert event_sequence(4) == [
               {:started, "e1"},
               {:finished, "e1"},
               {:started, "e2"},
               {:finished, "e2"}
             ]
    end
  end

  # ── Disjoint edits are no longer a barrier against each other ────────

  describe "cross-call conflict detection" do
    test "two file_edits to DIFFERENT files run in parallel", %{dir: dir} do
      # `file_edit` returns `concurrency_safe? false` unconditionally, which made
      # it a barrier against EVERYTHING — including another edit to an unrelated
      # file, which cannot race it. `Tools.ConflictScope` compares canonicalised
      # target paths, so the pair that genuinely cannot interfere now overlaps.
      # The same-file pair above still serialises; that is the point.
      a = Path.join(dir, "a.txt")
      b = Path.join(dir, "b.txt")
      File.write!(a, "x")
      File.write!(b, "x")
      state = %{session_id: "test", tool_executor: OverlapExecutor, test_pid: self()}

      ctx =
        StreamingToolExecutor.start(state)
        |> fire([edit_call("e1", a, "x", "y"), edit_call("e2", b, "x", "y")], state)

      _ = StreamingToolExecutor.collect_results(ctx)

      assert event_sequence(4) |> Enum.take(2) |> Enum.map(&elem(&1, 0)) == [:started, :started],
             "disjoint edits were serialised against each other"
    end

    test "an edit and a read of the SAME file still serialise", %{dir: dir} do
      # `file_read` is per-call safe, so without read targets in the comparison
      # it would batch alongside a write to the very file it is reading.
      path = Path.join(dir, "shared.txt")
      File.write!(path, "x")
      state = %{session_id: "test", tool_executor: OverlapExecutor, test_pid: self()}

      calls = [
        edit_call("w1", path, "x", "y"),
        %{id: "r1", name: "file_read", arguments: %{"path" => path}}
      ]

      ctx = fire(StreamingToolExecutor.start(state), calls, state)
      _ = StreamingToolExecutor.collect_results(ctx)

      assert event_sequence(4) == [
               {:started, "w1"},
               {:finished, "w1"},
               {:started, "r1"},
               {:finished, "r1"}
             ]
    end
  end

  # ── Parallel reads must stay parallel ────────────────────────────────

  describe "concurrency-safe calls" do
    test "still start eagerly and overlap", %{dir: dir} do
      state = %{session_id: "test", tool_executor: OverlapExecutor, test_pid: self()}
      path = Path.join(dir, "r.txt")
      File.write!(path, "x")

      calls =
        for i <- 1..3 do
          %{id: "r#{i}", name: SafeTool.name(), arguments: %{"path" => path}}
        end

      started = System.monotonic_time(:millisecond)
      ctx = fire(StreamingToolExecutor.start(state), calls, state)

      # All three announce a start before ANY of them finishes — that is
      # parallelism, and it is the property the eager streaming path exists for.
      assert event_sequence(3) |> Enum.map(&elem(&1, 0)) == [:started, :started, :started]

      _ = StreamingToolExecutor.collect_results(ctx)
      elapsed = System.monotonic_time(:millisecond) - started

      # 3 × 120 ms serialised would exceed 300 ms.
      assert elapsed < 300, "reads were serialised (#{elapsed}ms)"
    end

    test "real file_read calls are declared safe and file_edit unsafe" do
      ctx = UseContext.empty()

      refute OptimalSystemAgent.Tools.Builtins.FileEdit.Tool.concurrency_safe?(%{}, ctx)
      assert OptimalSystemAgent.Tools.Builtins.FileRead.Tool.concurrency_safe?(%{}, ctx)
    end
  end

  # ── Barrier semantics match the orchestrator ─────────────────────────

  describe "barrier semantics" do
    test "a safe batch fired after an unsafe call waits for it" do
      state = %{
        session_id: "test",
        tool_executor: OverlapExecutor,
        test_pid: self(),
        hold_ms: 80
      }

      calls = [
        %{id: "u1", name: UnsafeTool.name(), arguments: %{}},
        %{id: "s1", name: SafeTool.name(), arguments: %{}},
        %{id: "s2", name: SafeTool.name(), arguments: %{}}
      ]

      ctx = fire(StreamingToolExecutor.start(state), calls, state)
      _ = StreamingToolExecutor.collect_results(ctx)

      seq = event_sequence(6)

      # The barrier runs alone and to completion first...
      assert Enum.take(seq, 2) == [{:started, "u1"}, {:finished, "u1"}]
      # ...and the safe pair behind it then runs in parallel with each other.
      assert Enum.slice(seq, 2, 2) |> Enum.map(&elem(&1, 0)) == [:started, :started]
    end

    test "an unsafe call waits for the safe batch already in flight" do
      state = %{
        session_id: "test",
        tool_executor: OverlapExecutor,
        test_pid: self(),
        hold_ms: 80
      }

      calls = [
        %{id: "s1", name: SafeTool.name(), arguments: %{}},
        %{id: "s2", name: SafeTool.name(), arguments: %{}},
        %{id: "u1", name: UnsafeTool.name(), arguments: %{}}
      ]

      ctx = fire(StreamingToolExecutor.start(state), calls, state)
      _ = StreamingToolExecutor.collect_results(ctx)

      seq = event_sequence(6)

      # Both safe calls start before either finishes (still parallel)...
      assert Enum.take(seq, 2) |> Enum.map(&elem(&1, 0)) == [:started, :started]
      # ...and the unsafe call starts only after BOTH have finished.
      assert List.last(seq) == {:finished, "u1"}
      assert Enum.at(seq, 4) == {:started, "u1"}
      assert Enum.slice(seq, 2, 2) |> Enum.map(&elem(&1, 0)) == [:finished, :finished]
    end
  end

  # ── Unknown tools fail closed, same as the orchestrator ──────────────

  test "an unregistered tool serialises (fail-closed)" do
    state = %{session_id: "test", tool_executor: OverlapExecutor, test_pid: self(), hold_ms: 60}

    calls = [
      %{id: "g1", name: "ghost_tool_not_registered", arguments: %{}},
      %{id: "g2", name: "ghost_tool_not_registered", arguments: %{}}
    ]

    ctx = fire(StreamingToolExecutor.start(state), calls, state)
    _ = StreamingToolExecutor.collect_results(ctx)

    assert event_sequence(4) == [
             {:started, "g1"},
             {:finished, "g1"},
             {:started, "g2"},
             {:finished, "g2"}
           ]
  end
end
