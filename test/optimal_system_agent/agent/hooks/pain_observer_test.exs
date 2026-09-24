defmodule OptimalSystemAgent.Agent.Hooks.PainObserverTest do
  @moduledoc """
  Direct unit tests for the pain-observer built-in hook handlers
  (`OptimalSystemAgent.Agent.Hooks.Handlers.pain_observer_tool/1`,
  `pain_observer_prompt/1`, `pain_lesson_flush/1`,
  `pain_lesson_flush_on_compact/1`) — the double-loop learning input.

  Calls the handler functions directly (same style as `Guardrails` and
  `MessageHandler` unit tests elsewhere in this suite), not through the full
  `Dispatch`/`Hooks` chain — these are pure business-logic units.

  async: false — the pain-repeat tracker and the pain-event buffer are
  shared named ETS tables.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks.Handlers
  alias OptimalSystemAgent.Learning.PainSink

  setup do
    session_id = "pain-observer-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> PainSink.clear(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "builtins/0 registration" do
    test "registers the pain-observer and flush handlers on the expected events" do
      builtins = Handlers.builtins()
      by_name = Map.new(builtins, &{&1.name, &1})

      assert by_name["pain_observer_tool"].event == :post_tool_use
      assert by_name["pain_observer_prompt"].event == :user_prompt_submit
      assert by_name["pain_lesson_flush"].event == :session_end
      assert by_name["pain_lesson_flush_on_compact"].event == :post_compact

      # Every built-in name is unique.
      names = Enum.map(builtins, & &1.name)
      assert Enum.uniq(names) == names
    end
  end

  describe "pain_observer_tool/1 — repeated calls" do
    test "the same tool + result repeated 3x records exactly one pain event",
         %{session_id: sid} do
      payload = %{tool_name: "file_read", result: "same content", session_id: sid}

      for _ <- 1..3, do: assert({:ok, ^payload} = Handlers.pain_observer_tool(payload))

      assert [event] = PainSink.events(sid)
      assert event.kind == :repeated_probe
    end

    test "a shell_execute repeat is classified as :reverification_loop",
         %{session_id: sid} do
      payload = %{tool_name: "shell_execute", result: "PASS", session_id: sid}
      for _ <- 1..3, do: Handlers.pain_observer_tool(payload)

      assert [event] = PainSink.events(sid)
      assert event.kind == :reverification_loop
    end

    test "a differing result in between resets the streak (no pain event)",
         %{session_id: sid} do
      Handlers.pain_observer_tool(%{tool_name: "file_read", result: "a", session_id: sid})
      Handlers.pain_observer_tool(%{tool_name: "file_read", result: "b", session_id: sid})
      Handlers.pain_observer_tool(%{tool_name: "file_read", result: "a", session_id: sid})

      assert PainSink.events(sid) == []
    end

    test "an empty result is exempted from repeat counting", %{session_id: sid} do
      payload = %{tool_name: "shell_output", result: "", session_id: sid}
      for _ <- 1..5, do: Handlers.pain_observer_tool(payload)

      assert PainSink.events(sid) == []
    end

    test "never raises when required keys are missing" do
      assert {:ok, %{}} = Handlers.pain_observer_tool(%{})
    end
  end

  describe "pain_observer_tool/1 — slow search" do
    test "a slow search-shaped tool call records a :slow_search pain event",
         %{session_id: sid} do
      payload = %{
        tool_name: "file_grep",
        result: "3 matches",
        duration_ms: 9_000,
        session_id: sid
      }

      assert {:ok, ^payload} = Handlers.pain_observer_tool(payload)

      assert [event] = PainSink.events(sid)
      assert event.kind == :slow_search
      assert event.detail =~ "file_grep"
    end

    test "a fast search-shaped tool call records nothing", %{session_id: sid} do
      payload = %{tool_name: "file_grep", result: "3 matches", duration_ms: 200, session_id: sid}
      Handlers.pain_observer_tool(payload)

      assert PainSink.events(sid) == []
    end

    test "a slow but non-search tool call records nothing", %{session_id: sid} do
      payload = %{tool_name: "memory_save", result: "ok", duration_ms: 20_000, session_id: sid}
      Handlers.pain_observer_tool(payload)

      assert PainSink.events(sid) == []
    end
  end

  describe "pain_observer_prompt/1 — user corrections" do
    test "a correction-phrased message records a :user_correction pain event",
         %{session_id: sid} do
      payload = %{
        message: "no, that's wrong, you should have read the file first",
        session_id: sid
      }

      assert {:ok, ^payload} = Handlers.pain_observer_prompt(payload)

      assert [event] = PainSink.events(sid)
      assert event.kind == :user_correction
      # The raw message is never stored in the pain event's detail.
      refute event.detail =~ "read the file first"
    end

    test "an ordinary message records nothing", %{session_id: sid} do
      Handlers.pain_observer_prompt(%{message: "please add a dark mode toggle", session_id: sid})
      assert PainSink.events(sid) == []
    end

    test "never raises when required keys are missing" do
      assert {:ok, %{}} = Handlers.pain_observer_prompt(%{})
    end
  end

  describe "pain_lesson_flush/1 and pain_lesson_flush_on_compact/1" do
    test "both drain the session's buffer into Memory", %{session_id: sid} do
      PainSink.record(sid, :command_fix, "retried")
      assert {:ok, %{session_id: ^sid}} = Handlers.pain_lesson_flush(%{session_id: sid})
      assert PainSink.events(sid) == []

      PainSink.record(sid, :slow_search, "slow")

      assert {:ok, %{session_id: ^sid}} =
               Handlers.pain_lesson_flush_on_compact(%{session_id: sid})

      assert PainSink.events(sid) == []
    end

    test "never raise when session_id is missing" do
      assert {:ok, %{}} = Handlers.pain_lesson_flush(%{})
      assert {:ok, %{}} = Handlers.pain_lesson_flush_on_compact(%{})
    end
  end
end
