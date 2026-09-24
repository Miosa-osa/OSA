defmodule OptimalSystemAgent.Agent.TurnTraceTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.TurnTrace

  defp sid, do: "trace-test-#{System.unique_integer([:positive])}"

  defp tool(name, at, ms, opts \\ []) do
    %{
      kind: :tool,
      at: at,
      name: name,
      duration_ms: ms,
      success: Keyword.get(opts, :success, true),
      read_only: Keyword.get(opts, :read_only, true),
      args_hash: Keyword.get(opts, :hash, 1),
      hint: Keyword.get(opts, :hint, "lib/a.ex")
    }
  end

  defp llm(at, ms, input \\ 100, output \\ 10) do
    %{
      kind: :llm,
      at: at,
      duration_ms: ms,
      model: "m",
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: 0,
      cost_usd: 0.001,
      ok: true
    }
  end

  defp meta(start, stop), do: %{turn: 1, status: :done, started_mono: start, ended_mono: stop}

  describe "summarize/2" do
    test "splits the wall clock into model, tools, approval, background and other" do
      events = [
        llm(1_000, 1_000),
        # two parallel tools: 1000-1500 and 1200-1600 -> 600ms of wall, not 900
        tool("file_read", 1_500, 500),
        tool("file_grep", 1_600, 400, hash: 2),
        llm(3_000, 1_000),
        # a 3s shell call of which 2s was the user deciding whether to allow it
        tool("shell_execute", 6_000, 3_000, read_only: false, hint: "make test"),
        %{
          kind: :approval,
          at: 5_000,
          tool: "shell_execute",
          wait_ms: 2_000,
          outcome: "allow_once"
        },
        tool("task_wait", 7_000, 1_000, read_only: false, hint: nil),
        llm(7_500, 500)
      ]

      s = TurnTrace.summarize(meta(0, 8_000), events)

      assert s.wall_ms == 8_000
      assert s.breakdown.model_ms == 2_500
      assert s.breakdown.approval_ms == 2_000
      assert s.breakdown.background_ms == 1_000
      # tool union 600 + 3000 + 1000 = 4600, minus approval and background
      assert s.tools.union_ms == 4_600
      assert s.breakdown.tool_ms == 1_600
      # busy = model 2500 + tools 4600 (no overlap) -> 900 unaccounted
      assert s.breakdown.other_ms == 900
      assert s.llm.calls == 3
      assert s.llm.input_tokens == 300
      assert s.background.calls == 1
      assert s.tools.calls == 3
      assert [%{name: "shell_execute", ms: 3_000} | _] = s.tools.slowest
    end

    test "counts only identical, successful, read-only repeats with no write between as wasted" do
      events = [
        tool("file_read", 1, 10, hash: 1),
        tool("file_read", 2, 10, hash: 1),
        tool("file_read", 3, 10, hash: 1),
        # a different file is not a repeat
        tool("file_read", 4, 10, hash: 2, hint: "lib/b.ex"),
        # an edit resets the window: re-reading after it is verification
        tool("file_edit", 5, 10, read_only: false, hash: 9),
        tool("file_read", 6, 10, hash: 1),
        # a failed probe does not make its retry wasted
        tool("file_grep", 7, 10, hash: 5, success: false),
        tool("file_grep", 8, 10, hash: 5)
      ]

      s = TurnTrace.summarize(meta(0, 100), events)

      assert s.wasted.count == 2
      assert s.wasted.ms == 20
      assert [%{name: "file_read", hint: "lib/a.ex", repeats: 2}] = s.wasted.items
    end

    test "a running turn measures up to now and recoveries are tallied by mechanism" do
      now = System.monotonic_time(:millisecond)

      events = [
        %{kind: :recovery, at: now, mechanism: "provider_retry", detail: "429"},
        %{kind: :recovery, at: now, mechanism: "provider_retry", detail: "429"},
        %{kind: :recovery, at: now, mechanism: "loop_recovery", detail: "cut off"}
      ]

      s =
        TurnTrace.summarize(
          %{turn: 2, status: :running, started_mono: now - 5_000, ended_mono: nil},
          events
        )

      assert s.status == "running"
      assert s.wall_ms >= 5_000
      assert s.recoveries.count == 3
      assert s.recoveries.by_kind == %{"provider_retry" => 2, "loop_recovery" => 1}
    end
  end

  describe "union_ms/1" do
    test "merges overlapping and nested intervals" do
      assert TurnTrace.union_ms([]) == 0
      assert TurnTrace.union_ms([{0, 10}, {5, 15}, {20, 30}, {21, 22}]) == 25
      assert TurnTrace.union_ms([{10, 5}]) == 0
    end
  end

  describe "read_only?/2" do
    test "file probes by name, shell only when provably read-only" do
      assert TurnTrace.read_only?("file_read", %{})
      refute TurnTrace.read_only?("file_edit", %{})
      assert TurnTrace.read_only?("shell_execute", %{"command" => "grep -rn foo lib"})
      refute TurnTrace.read_only?("shell_execute", %{"command" => "rm -rf build"})
      refute TurnTrace.read_only?("shell_execute", %{})
    end
  end

  describe "recording lifecycle" do
    test "events land on the current turn, end_turn closes it, latest/turns read it back" do
      id = sid()
      on_exit(fn -> TurnTrace.clear(id) end)

      assert TurnTrace.latest(id) == nil

      TurnTrace.begin_turn(id, %{
        model: "glm-5.2:cloud",
        provider: :ollama_cloud,
        prompt: "fix it"
      })

      TurnTrace.record_llm(id, %{
        duration_ms: 40,
        usage: %{input_tokens: 10, output_tokens: 2},
        ok: true
      })

      TurnTrace.record_tool(id, %{
        name: "file_read",
        args: %{"path" => "/x/lib/a.ex"},
        duration_ms: 5,
        success: true
      })

      TurnTrace.record_approval_wait(id, %{tool: "file_edit", wait_ms: 7, outcome: :allow_once})
      TurnTrace.record_recovery(id, :provider_retry, "timeout")

      running = TurnTrace.latest(id)
      assert running.status == "running"
      assert running.model == "glm-5.2:cloud"
      assert running.llm.calls == 1
      assert running.tools.calls == 1
      assert [%{hint: "/x/lib/a.ex"}] = running.tools.slowest
      assert running.approval.ms == 7
      assert running.recoveries.by_kind == %{"provider_retry" => 1}

      TurnTrace.end_turn(id)
      assert TurnTrace.latest(id).status == "done"

      # the summary is what the HTTP API serves, so it must be JSON-encodable
      assert {:ok, _} = Jason.encode(TurnTrace.latest(id))
    end

    test "keeps the last five turns and drops older turns' events" do
      id = sid()
      on_exit(fn -> TurnTrace.clear(id) end)

      for n <- 1..7 do
        TurnTrace.begin_turn(id, %{prompt: "turn #{n}"})
        TurnTrace.record_tool(id, %{name: "file_read", args: %{"n" => n}, duration_ms: n})
        TurnTrace.end_turn(id)
      end

      turns = TurnTrace.turns(id)
      assert Enum.map(turns, & &1.turn) == [7, 6, 5, 4, 3]
      assert Enum.all?(turns, &(&1.tools.calls == 1))
      assert :ets.lookup(:osa_turn_trace_events, {id, 1}) == []
    end

    test "a call made under a tool alias is recorded under the canonical name" do
      id = sid()
      on_exit(fn -> TurnTrace.clear(id) end)

      TurnTrace.begin_turn(id)

      TurnTrace.record_tool(id, %{
        name: "bash_execute",
        args: %{"command" => "grep -rn foo lib"},
        duration_ms: 3
      })

      TurnTrace.record_tool(id, %{
        name: "shell_execute",
        args: %{"command" => "grep -rn foo lib"},
        duration_ms: 3
      })

      s = TurnTrace.latest(id)
      assert [%{name: "shell_execute", calls: 2}] = s.tools.per_tool
      # same canonical call, read-only, repeated: the second is waste
      assert s.wasted.count == 1
    end

    test "recording with no open turn, or for a non-session, is a no-op" do
      assert TurnTrace.record_tool(sid(), %{name: "file_read"}) == :ok
      assert TurnTrace.record_llm(nil, %{}) == :ok
      assert TurnTrace.record_recovery(nil, :tool_retry, "x") == :ok
    end
  end

  describe "format/1" do
    test "renders the compact table" do
      events = [
        llm(2_000, 2_000, 41_200, 3_100),
        tool("shell_execute", 8_100, 6_100, read_only: false, hint: "mix test"),
        tool("file_read", 8_500, 400),
        tool("file_read", 8_900, 400),
        %{kind: :recovery, at: 9_000, mechanism: "provider_retry", detail: "429 rate limited"}
      ]

      text = TurnTrace.format(TurnTrace.summarize(meta(0, 10_000), events))

      assert text =~ "Turn 1 · done · 10.0s wall"
      assert text =~ ~r/model\s+2\.0s\s+20%\s+1 call · 41\.2k in \/ 3\.1k out/
      assert text =~ ~r/shell_execute\s+1\s+6\.1s\s+6\.1s/
      assert text =~ "slowest calls"
      assert text =~ "mix test"
      assert text =~ "retries/recoveries: 1"
      assert text =~ "wasted: 1 repeated read-only probe (400ms)"
    end

    test "nil renders the empty state" do
      assert TurnTrace.format(nil) =~ "No turn recorded"
    end
  end
end
