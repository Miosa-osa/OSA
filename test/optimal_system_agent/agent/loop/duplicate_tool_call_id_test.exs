defmodule OptimalSystemAgent.Agent.Loop.DuplicateToolCallIdTest do
  @moduledoc """
  Defect 2 — colliding tool-call ids silently collapse.

  Two independent id→result maps are built per turn:

    * `ToolOrchestrator.dispatch/3` — restores the model's submission order
    * `ReactLoop` — merges streaming results with freshly executed ones

  Both are `Map.new(..., fn {tc, r} -> {tc.id, {tc, r}} end)`. When a provider
  emits two `tool_use` blocks under the SAME id, the second entry overwrites the
  first: one tool's result is lost, and the assistant message ships two
  `tool_use` blocks against a single `tool_result`. A strict provider
  (Anthropic) then rejects the *FOLLOWING* request — the turn after the one that
  actually went wrong is the one that breaks, which is what makes this so hard
  to trace in the field.

  The repair is a single canonical `uniquify_ids/1` applied ONCE at ingest,
  upstream of both maps. Fixing either map alone leaves the other broken, and a
  second divergent fix is how a bug like this survives.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator

  defmodule EchoExecutor do
    @moduledoc false
    # Minimal stand-in for `ToolExecutor`: echoes the tool's own arguments so
    # each call's result is distinguishable even when the ids collide.
    def execute_tool_call(tc, _state) do
      payload = Map.get(tc.arguments || %{}, "payload", "?")
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: payload}, payload}
    end
  end

  defp call(id, payload) do
    %{id: id, name: "unregistered_test_tool", arguments: %{"payload" => payload}}
  end

  describe "uniquify_ids/1" do
    test "two calls sharing an id come back with distinct ids, in order" do
      calls = [call("toolu_dup", "first"), call("toolu_dup", "second")]

      assert [a, b] = ToolOrchestrator.uniquify_ids(calls)

      assert a.id != b.id, "colliding ids must not survive ingest"
      assert a.id == "toolu_dup", "the FIRST occurrence keeps the provider's id verbatim"
      assert a.arguments["payload"] == "first"
      assert b.arguments["payload"] == "second"
    end

    test "already-unique ids are a strict no-op" do
      calls = [call("a", "1"), call("b", "2"), call("c", "3")]
      assert ToolOrchestrator.uniquify_ids(calls) == calls
    end

    test "a rewritten id cannot collide with a real later id" do
      # "x" appears twice; the natural rewrite target "x#1" is ALSO a real id in
      # the same batch. Every emitted id must still be distinct.
      calls = [call("x", "1"), call("x", "2"), call("x#1", "3"), call("x#1", "4")]

      ids = calls |> ToolOrchestrator.uniquify_ids() |> Enum.map(& &1.id)

      assert length(Enum.uniq(ids)) == 4, "got #{inspect(ids)}"
    end

    test "missing ids are minted rather than left nil (two nils collapse too)" do
      calls = [
        %{name: "unregistered_test_tool", arguments: %{"payload" => "1"}},
        %{name: "unregistered_test_tool", arguments: %{"payload" => "2"}}
      ]

      ids = calls |> ToolOrchestrator.uniquify_ids() |> Enum.map(& &1.id)

      assert Enum.all?(ids, &is_binary/1)
      assert length(Enum.uniq(ids)) == 2
    end

    test "more than two collisions all stay distinct" do
      calls = for n <- 1..5, do: call("same", "p#{n}")
      ids = calls |> ToolOrchestrator.uniquify_ids() |> Enum.map(& &1.id)
      assert length(Enum.uniq(ids)) == 5
    end
  end

  describe "dispatch/3 — the id-keyed map that loses a result" do
    @state %{session_id: "dup-id-#{System.unique_integer([:positive])}"}

    test "PRECONDITION: raw duplicate ids really do collapse in dispatch's map" do
      # Proves the defect is real, not theoretical: the map is keyed by id, so
      # two entries with the same key leave one result unreachable and BOTH
      # output rows carry the same (last-writer) result.
      raw = [call("toolu_dup", "first"), call("toolu_dup", "second")]

      results =
        ToolOrchestrator.dispatch(raw, @state, executor: EchoExecutor, timeout_ms: 5_000)

      payloads = Enum.map(results, fn {_tc, {_msg, str}} -> str end)

      assert payloads == ["second", "second"],
             "expected the collision to lose 'first'; got #{inspect(payloads)}"
    end

    test "both results survive when ids are uniquified at ingest (as ReactLoop now does)" do
      calls =
        [call("toolu_dup", "first"), call("toolu_dup", "second")]
        |> ToolOrchestrator.uniquify_ids()

      results =
        ToolOrchestrator.dispatch(calls, @state, executor: EchoExecutor, timeout_ms: 5_000)

      assert length(results) == 2

      payloads = Enum.map(results, fn {_tc, {_msg, str}} -> str end)
      assert payloads == ["first", "second"], "both results must survive, in submission order"

      # Every tool_result must be addressable by a DISTINCT tool_call_id, which
      # is what keeps the assistant's tool_use blocks paired for the next turn.
      ids = Enum.map(results, fn {_tc, {msg, _str}} -> msg.tool_call_id end)
      assert length(Enum.uniq(ids)) == 2
    end
  end

  describe "the repair is wired at ingest, upstream of BOTH maps" do
    # A structural assertion, deliberately: the whole point of this defect is
    # that patching one map and not the other looks green while staying broken.
    test "ReactLoop applies uniquify_ids/1 on every tool-call ingest path" do
      source = File.read!("lib/optimal_system_agent/agent/loop/react_loop.ex")

      occurrences =
        source
        |> String.split("ToolOrchestrator.uniquify_ids(tool_calls)")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 2,
             "expected both handle_result/3 tool-call clauses (normal + truncated) to " <>
               "uniquify at ingest, found #{occurrences}"
    end
  end
end
