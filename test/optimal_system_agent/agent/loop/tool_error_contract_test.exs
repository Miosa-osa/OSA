defmodule OptimalSystemAgent.Agent.Loop.ToolErrorContractTest do
  @moduledoc """
  NON-FATAL TOOL ERROR contract (Codex `FunctionCallError` parity).

  Proves the two-class distinction end to end:

    * RESPOND-TO-MODEL (the default) — a tool that raises, throws, exits,
      returns `{:error, _}`, or returns garbage produces a normal,
      model-readable tool result and the turn CONTINUES.
    * FATAL — only an explicit `{:fatal, reason}` (or a raised
      `ToolError.Fatal`) still aborts the turn.
    * A permission DENIAL's reason text reaches the model as a tool result,
      and repeated denials no longer trip the doom-loop hard halt.
    * Tool metadata (`:diff`, `:stats`, `:path`) still rides on the
      `:tool_result` event — the TUI/SSE contract is unchanged.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature
  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.Registry

  @registry_key {Registry, :builtin_tools}

  # ── Stub tools ────────────────────────────────────────────────────────

  defmodule RaisingTool do
    @moduledoc false
    def name, do: "test_raising_tool"
    def description, do: "raises"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: raise("boom from inside the tool")
  end

  defmodule ExitingTool do
    @moduledoc false
    def name, do: "test_exiting_tool"
    def description, do: "exits"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: exit(:simulated_tool_exit)
  end

  defmodule ThrowingTool do
    @moduledoc false
    def name, do: "test_throwing_tool"
    def description, do: "throws"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: throw(:simulated_tool_throw)
  end

  defmodule ErrorTool do
    @moduledoc false
    def name, do: "test_error_tool"
    def description, do: "errors"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: {:error, "the file was not found in the workspace"}
  end

  defmodule GarbageTool do
    @moduledoc false
    def name, do: "test_garbage_tool"
    def description, do: "returns an unexpected shape"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: :who_knows
  end

  defmodule FatalTool do
    @moduledoc false
    def name, do: "test_fatal_tool"
    def description, do: "fatal"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: {:fatal, "the agent workspace is gone"}
  end

  defmodule MetadataTool do
    @moduledoc false
    def name, do: "test_metadata_tool"
    def description, do: "returns metadata"
    def parameters, do: %{"type" => "object", "properties" => %{}}

    def execute(_args),
      do: {:ok, "wrote it", %{diff: "@@ -1 +1 @@", stats: %{added: 1}, path: "/tmp/x"}}
  end

  @stubs %{
    "test_raising_tool" => RaisingTool,
    "test_exiting_tool" => ExitingTool,
    "test_throwing_tool" => ThrowingTool,
    "test_error_tool" => ErrorTool,
    "test_garbage_tool" => GarbageTool,
    "test_fatal_tool" => FatalTool,
    "test_metadata_tool" => MetadataTool
  }

  setup do
    prev = :persistent_term.get(@registry_key, :__absent__)
    existing = if prev == :__absent__, do: %{}, else: prev
    :persistent_term.put(@registry_key, Map.merge(existing, @stubs))

    on_exit(fn ->
      case prev do
        :__absent__ -> :persistent_term.erase(@registry_key)
        value -> :persistent_term.put(@registry_key, value)
      end
    end)

    :ok
  end

  defp state(overrides \\ []) do
    Enum.into(overrides, %{
      session_id: "tool-error-#{System.unique_integer([:positive, :monotonic])}",
      turn_count: 0,
      iteration: 0,
      permission_tier: :full,
      permission_mode: :overdrive,
      messages: [],
      recent_failure_signatures: []
    })
  end

  defp call(name, args \\ %{}),
    do: %{id: "tc-#{System.unique_integer([:positive, :monotonic])}", name: name, arguments: args}

  # ── RESPOND-TO-MODEL: the turn survives every ordinary failure ─────────

  describe "RESPOND-TO-MODEL class (the default)" do
    test "a raising tool becomes a model-readable result — the turn continues" do
      tc = call("test_raising_tool")

      assert {tool_msg, result} = ToolExecutor.execute_tool_call(tc, state())

      # 2-tuple (not the fatal 3-tuple) => the turn is NOT aborted.
      assert tuple_size({tool_msg, result}) == 2
      assert String.starts_with?(result, "Error:")
      assert result =~ "boom from inside the tool"

      # The model actually sees it, attributed to the right call.
      assert tool_msg.role == "tool"
      assert tool_msg.tool_call_id == tc.id
      assert tool_msg.name == tc.name
      assert tool_msg.content =~ "boom from inside the tool"
    end

    test "a tool that EXITS is recovered with its reason (was: turn-killing task crash)" do
      tc = call("test_exiting_tool")

      assert {tool_msg, result} = ToolExecutor.execute_tool_call(tc, state())
      assert String.starts_with?(result, "Error:")
      assert result =~ "simulated_tool_exit"
      assert tool_msg.content == result
    end

    test "a tool that THROWS is recovered with its thrown value" do
      tc = call("test_throwing_tool")

      assert {_msg, result} = ToolExecutor.execute_tool_call(tc, state())
      assert String.starts_with?(result, "Error:")
      assert result =~ "simulated_tool_throw"
    end

    test "an {:error, reason} tool keeps the existing \"Error:\" prefix convention" do
      tc = call("test_error_tool")

      assert {_msg, result} = ToolExecutor.execute_tool_call(tc, state())
      assert String.starts_with?(result, "Error:")
      assert result =~ "the file was not found in the workspace"
    end

    test "an unexpected return shape is reported, not crashed on" do
      tc = call("test_garbage_tool")

      assert {_msg, result} = ToolExecutor.execute_tool_call(tc, state())
      assert String.starts_with?(result, "Error:")
      assert result =~ "unexpected result shape"
    end

    test "several failing calls in a row all return results — nothing aborts" do
      s = state()

      results =
        for name <- [
              "test_raising_tool",
              "test_exiting_tool",
              "test_throwing_tool",
              "test_error_tool"
            ] do
          {_msg, result} = ToolExecutor.execute_tool_call(call(name), s)
          result
        end

      assert length(results) == 4
      assert Enum.all?(results, &String.starts_with?(&1, "Error:"))
    end
  end

  # ── FATAL: still aborts ───────────────────────────────────────────────

  describe "FATAL class" do
    test "a {:fatal, reason} tool returns the fatal 3-tuple" do
      tc = call("test_fatal_tool")

      assert {tool_msg, result, {:fatal, message}} =
               ToolExecutor.execute_tool_call(tc, state())

      assert message =~ "the agent workspace is gone"
      # History stays valid: the fatal result is still a well-formed tool msg.
      assert tool_msg.tool_call_id == tc.id
      assert tool_msg.name == tc.name
      assert String.starts_with?(result, "Error:")
      assert result =~ "fatal"
    end

    test "normalize_results/1 strips the fatal marker and surfaces the message" do
      tc_ok = call("a")
      tc_fatal = call("b")

      results = [
        {tc_ok, {%{role: "tool", tool_call_id: tc_ok.id, content: "fine"}, "fine"}},
        {tc_fatal, ToolError.fatal_result(tc_fatal, "disk gone")}
      ]

      assert {normalized, "disk gone"} = ToolError.normalize_results(results)

      # Both tool messages survive — the assistant's tool_calls are never
      # orphaned in message history.
      assert length(normalized) == 2
      assert Enum.all?(normalized, fn {_tc, r} -> tuple_size(r) == 2 end)
      assert [_, {^tc_fatal, {msg, _}}] = normalized
      assert msg.tool_call_id == tc_fatal.id
    end

    test "no fatal result => normalize_results/1 reports nil (turn continues)" do
      tc = call("a")
      results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: "ok"}, "ok"}}]

      assert {^results, nil} = ToolError.normalize_results(results)
    end

    test "ToolError.run/1 classifies the two variants" do
      assert {:ok, 42} = ToolError.run(fn -> 42 end)
      assert {:error, msg} = ToolError.run(fn -> raise "nope" end)
      assert msg =~ "nope"
      assert {:fatal, "hard stop"} = ToolError.run(fn -> ToolError.fatal!("hard stop") end)
      assert {:fatal, "bad"} = ToolError.run(fn -> exit({:fatal, "bad"}) end)
      assert {:error, _} = ToolError.run(fn -> exit(:whatever) end)
      assert {:error, _} = ToolError.run(fn -> throw(:whatever) end)
    end
  end

  # ── Permission denial reaches the model ───────────────────────────────

  describe "permission denial" do
    setup do
      prior_interactive =
        Application.get_env(:optimal_system_agent, :interactive_permissions, false)

      prior_bypass =
        Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      Application.put_env(:optimal_system_agent, :interactive_permissions, false)
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      on_exit(fn ->
        Application.put_env(
          :optimal_system_agent,
          :interactive_permissions,
          prior_interactive
        )

        Application.put_env(
          :optimal_system_agent,
          :non_interactive_permission_bypass,
          prior_bypass
        )
      end)

      :ok
    end

    test "a denial's REASON is returned to the model as a tool result, not an abort" do
      tc = call("test_error_tool")
      s = state(permission_mode: :ask, permission_tier: :full)

      assert {tool_msg, result} = ToolExecutor.execute_tool_call(tc, s)

      # 2-tuple => the turn continues.
      assert String.starts_with?(result, "Blocked:")
      assert result =~ "requires interactive approval"
      assert tool_msg.tool_call_id == tc.id
      assert tool_msg.content =~ "requires interactive approval"
    end

    test "an explicit user decline surfaces its reason verbatim" do
      tc = call("file_write", %{"path" => "/tmp/x"})

      assert {:blocked, message} =
               ToolExecutor.apply_permission_decision(:deny, nil, tc, state())

      assert message =~ "you declined to run file_write"
      assert ToolError.user_decision?(message)
    end

    test "reject-with-steer feeds the user's correction back into the turn" do
      tc = call("file_write", %{"path" => "/tmp/x"})

      assert {:steer, "edit the other file instead"} =
               ToolExecutor.apply_permission_decision(
                 :clarify,
                 "edit the other file instead",
                 tc,
                 state()
               )
    end

    test "repeated denials do NOT trip the doom-loop hard halt" do
      tc = call("file_write", %{"path" => "/tmp/x"})
      denial = "Blocked: you declined to run file_write"
      msg = %{role: "tool", tool_call_id: tc.id, content: denial}
      results = [{tc, {msg, denial}}]

      s =
        Enum.reduce(1..5, state(), fn _, acc ->
          assert {:ok, next} = FailureSignature.check(results, [tc], acc)
          next
        end)

      # Nothing accumulated: an operator decision is not a failure signature.
      assert s.recent_failure_signatures == []
    end

    test "a genuine repeated tool failure STILL trips the detector" do
      tc = call("file_edit", %{"path" => "/tmp/x"})
      err = "Error: old_string not found in /tmp/x"
      msg = %{role: "tool", tool_call_id: tc.id, content: err}
      results = [{tc, {msg, err}}]

      {:ok, s1} = FailureSignature.check(results, [tc], state())
      assert s1.recent_failure_signatures != []
    end
  end

  # ── TUI/SSE contract unchanged ────────────────────────────────────────

  describe "result shapes the TUI/SSE depend on" do
    test "tool metadata (:diff, :stats, :path) still rides on the :tool_result event" do
      s = state()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s.session_id}")

      assert {_msg, "wrote it"} =
               ToolExecutor.execute_tool_call(call("test_metadata_tool"), s)

      assert_receive {:osa_event, %{type: :tool_result, diff: "@@ -1 +1 @@", path: "/tmp/x"} = ev},
                     2_000

      assert ev.stats == %{added: 1}
      assert ev.success
    end

    test "a recovered failure still emits a :tool_result event with success: false" do
      s = state()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s.session_id}")

      assert {_msg, result} = ToolExecutor.execute_tool_call(call("test_exiting_tool"), s)
      assert String.starts_with?(result, "Error:")

      assert_receive {:osa_event, %{type: :tool_call, phase: "end", success: _}}, 2_000
      assert_receive {:osa_event, %{type: :tool_result, name: "test_exiting_tool"}}, 2_000
    end
  end
end
