defmodule OptimalSystemAgent.Agent.LoopRestoreRepairsOrphanedToolUseTest do
  @moduledoc """
  Reproduces the audit-item-2 defect: a crash mid tool-call leaves a
  `tool_use` in the persisted transcript with no `tool_result` at all.
  `Loop.DurableLog` gives at-least-once replay for a step it actually
  RECORDED, but a call that was in flight when the process died was never
  recorded either way — before the fix, `Loop.init/1` did no repair, so the
  first post-restore request carried the orphan straight to the provider and
  400'd (the same request-shape failure `HistorySanitizer` exists to
  prevent).

  Pins the fix: on restore, every orphaned `tool_use` gets a result saying
  the call was interrupted by a restart and its outcome is UNKNOWN (not
  "safe to retry" — it may have already run and mutated real state), so the
  model checks current state before deciding whether to repeat it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  setup do
    case Process.whereis(OptimalSystemAgent.SessionRegistry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry})

      _pid ->
        :ok
    end

    :ok
  end

  defp sid, do: "loop-restore-#{System.unique_integer([:positive])}"

  defp init_opts(messages) do
    [
      session_id: sid(),
      messages: messages,
      provider: :mock,
      model: "mock-model-1.0",
      working_dir: File.cwd!()
    ]
  end

  test "an orphaned tool_use from a mid-call crash gets an 'outcome unknown' result, not silence" do
    tc = %{id: "tc_crashed", name: "shell_execute", arguments: %{"command" => "rm -rf tmp/"}}

    messages = [
      %{role: "user", content: "clean up the tmp directory"},
      %{role: "assistant", content: "", tool_calls: [tc]}
      # Process died here — no tool_result was ever appended, by either
      # DurableLog (never recorded a completion) or the loop itself.
    ]

    assert {:ok, state} = Loop.init(init_opts(messages))

    tool_result =
      Enum.find(state.messages, fn m ->
        (Map.get(m, :tool_call_id) || Map.get(m, "tool_call_id")) == "tc_crashed"
      end)

    refute is_nil(tool_result),
           "the orphaned tool_use must be filled on restore, not left dangling"

    assert tool_result.role == "tool"

    # Must NOT claim the call was safely interrupted / never ran — it may
    # have already executed (e.g. that `rm -rf` may have already happened).
    refute tool_result.content =~ "Interrupted by user",
           "a crash-restart placeholder must not reuse the user-interrupt wording — the " <>
             "semantics differ: an interrupt means the call is KNOWN not to have completed"

    assert tool_result.content =~ "restart"
    assert tool_result.content =~ "unknown" or tool_result.content =~ "UNKNOWN"

    # Placement: immediately after the assistant message that owns it, so the
    # very next request is provider-shape-valid.
    idx = Enum.find_index(state.messages, &(&1 == tool_result))
    owner = Enum.at(state.messages, idx - 1)
    assert owner.tool_calls == [tc]
  end

  test "an already-answered tool_use is left completely alone" do
    tc = %{id: "tc_done", name: "read_file", arguments: %{}}

    messages = [
      %{role: "assistant", content: "", tool_calls: [tc]},
      %{role: "tool", tool_call_id: "tc_done", content: "real file contents"}
    ]

    assert {:ok, state} = Loop.init(init_opts(messages))
    assert state.messages == messages
  end

  test "a clean restore (no tool_calls at all) is a no-op" do
    messages = [
      %{role: "user", content: "hello"},
      %{role: "assistant", content: "hi there"}
    ]

    assert {:ok, state} = Loop.init(init_opts(messages))
    assert state.messages == messages
  end

  test "a fresh session (no explicit messages) starts empty, not with a phantom repair" do
    assert {:ok, state} = Loop.init(session_id: sid(), working_dir: File.cwd!())
    assert state.messages == []
  end
end
