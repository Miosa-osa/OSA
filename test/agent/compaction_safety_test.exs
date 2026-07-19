defmodule OptimalSystemAgent.Agent.CompactionSafetyTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Agent.CompactionSafety` — the three
  compaction provider-safety guarantees ported from grok's
  `xai-grok-compaction` crate:

    1. Tool-pair-safe tail selection  (select.rs)   — `safe_split_index/2`, `select_tail/3`
    2. Active-agent reminder          (reminder.rs) — `active_agent_reminder/1`, `wrap_system_reminder/1`
    3. Degenerate-summary retry       (sampler.rs)  — `sample_with_retry/2`, `degenerate_summary?/1`
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.CompactionSafety, as: CS
  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.RunStore

  # ── Message builders (OSA message shape) ──────────────────────────────
  defp user(c \\ "u"), do: %{role: "user", content: c}
  defp asst(c \\ "a"), do: %{role: "assistant", content: c}
  defp asst_tools(), do: %{role: "assistant", content: "", tool_calls: [%{name: "x", id: "1"}]}
  defp tool(c \\ "t"), do: %{role: "tool", content: c, tool_call_id: "1"}

  # ---------------------------------------------------------------------------
  # 1. Tool-pair-safe tail selection (select.rs)
  # ---------------------------------------------------------------------------

  describe "tool_result?/1" do
    test "true only for role == tool" do
      assert CS.tool_result?(tool())
      assert CS.tool_result?(%{role: :tool})
      refute CS.tool_result?(user())
      refute CS.tool_result?(asst_tools())
      refute CS.tool_result?(%{})
      refute CS.tool_result?("nope")
    end
  end

  describe "safe_split_index/2" do
    test "leaves a safe (non-tool) candidate unchanged" do
      msgs = [user(), asst(), user(), asst()]
      assert CS.safe_split_index(msgs, 2) == 2
    end

    test "snaps forward past a contiguous tool-result run" do
      # [user, asst, asst(tools), tool, tool, asst]
      # candidate 3 lands on the first tool → snap past both tools to 5.
      msgs = [user(), asst(), asst_tools(), tool(), tool(), asst()]
      assert CS.safe_split_index(msgs, 3) == 5
    end

    test "snaps forward from the middle of a tool run" do
      msgs = [asst_tools(), tool(), tool(), tool(), asst()]
      assert CS.safe_split_index(msgs, 2) == 4
    end

    test "returns total when candidate is at or beyond the end" do
      msgs = [user(), asst()]
      assert CS.safe_split_index(msgs, 2) == 2
      assert CS.safe_split_index(msgs, 99) == 2
    end

    test "clamps a negative candidate to 0 (and 0 is safe when not a tool)" do
      msgs = [user(), asst()]
      assert CS.safe_split_index(msgs, -5) == 0
    end

    test "an all-tool tail snaps all the way to total" do
      msgs = [asst_tools(), tool(), tool()]
      assert CS.safe_split_index(msgs, 1) == 3
    end
  end

  describe "select_tail/3 (grok select.rs parity)" do
    # token_fun reads a :tok field per message.
    defp tok(n), do: %{role: "user", content: "x", tok: n}
    defp tokf, do: fn m -> Map.get(m, :tok, 0) end

    test "empty list returns :none" do
      assert CS.select_tail([], 100, tokf()) == :none
    end

    test "whole list within budget returns :none" do
      assert CS.select_tail([tok(10), tok(20)], 1000, tokf()) == :none
    end

    test "splits at the correct backward-budget index" do
      # counts [40,30,20,10], target 30 → keep last two (30), compact 0..2.
      msgs = [tok(40), tok(30), tok(20), tok(10)]
      assert CS.select_tail(msgs, 30, tokf()) == {:ok, 2}
    end

    test "snaps the split forward past tool results" do
      # [user,asst,asst,tool,tool,asst] counts [10,10,10,50,50,10] target 60.
      # Backward keep: 10 (idx5) + 50 (idx4) = 60; adding idx3 (50) overflows →
      # naive split 4 lands on a tool → snap forward to 5.
      msgs = [
        Map.put(user(), :tok, 10),
        Map.put(asst(), :tok, 10),
        Map.put(asst_tools(), :tok, 10),
        Map.put(tool(), :tok, 50),
        Map.put(tool(), :tok, 50),
        Map.put(asst(), :tok, 10)
      ]

      assert CS.select_tail(msgs, 60, tokf()) == {:ok, 5}
    end

    test "returns :none when snapping past all tool results eats the tail" do
      msgs = [
        Map.put(asst_tools(), :tok, 10),
        Map.put(tool(), :tok, 50),
        Map.put(tool(), :tok, 50)
      ]

      # target 0 → naive split lands on a tool, snap walks to total → :none.
      assert CS.select_tail(msgs, 0, tokf()) == :none
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Active-agent reminder (reminder.rs)
  # ---------------------------------------------------------------------------

  describe "wrap_system_reminder/1" do
    test "joins non-blank sections and wraps in a system-reminder tag" do
      out = CS.wrap_system_reminder(["## A\nx", "", "   ", "## B\ny"])
      assert out == "<system-reminder>\n## A\nx\n\n## B\ny\n</system-reminder>"
    end

    test "returns nil when every section is blank" do
      assert CS.wrap_system_reminder([]) == nil
      assert CS.wrap_system_reminder(["", "  \n\t"]) == nil
    end
  end

  describe "active_agent_reminder/1 (live-state integration)" do
    test "returns nil for a fresh session with nothing active" do
      session = unique_session()
      assert CS.active_agent_reminder(session) == nil
      assert CS.build_reminder_message(session) == nil
    end

    test "renders actionable TODO items and omits completed ones" do
      session = unique_session()

      {:ok, t1} = Tasks.add_task(session, "wire the API")
      {:ok, t2} = Tasks.add_task(session, "scaffold the app")
      :ok = Tasks.start_task(session, t1)
      :ok = Tasks.complete_task(session, t2)

      out = CS.active_agent_reminder(session)
      assert is_binary(out)
      assert String.starts_with?(out, "<system-reminder>")
      assert String.ends_with?(out, "</system-reminder>")
      assert out =~ "## TODO List"
      assert out =~ "[in_progress]"
      assert out =~ "wire the API"
      # Completed task collapses to a trailer count, not a line.
      refute out =~ "scaffold the app"
      assert out =~ "(1 completed)"

      Tasks.clear_tasks(session)
    end

    test "build_reminder_message wraps the reminder as a system message" do
      session = unique_session()
      {:ok, _} = Tasks.add_task(session, "keep tracking this")

      msg = CS.build_reminder_message(session)
      assert %{role: "system", content: content} = msg
      assert content =~ "keep tracking this"

      Tasks.clear_tasks(session)
    end

    test "renders still-running subagents with poll/cancel tool names" do
      session = unique_session()
      agent_id = "sub-" <> rand()

      :ok =
        RunStore.start_run(%{
          agent_id: agent_id,
          parent_session_id: session,
          role: "explore",
          task: "find the orphaned tool results"
        })

      out = CS.active_agent_reminder(session)
      assert is_binary(out)
      assert out =~ "## Running Subagents"
      assert out =~ "subagent_id: `#{agent_id}`"
      assert out =~ "type: `explore`"
      assert out =~ "find the orphaned tool results"
      # Poll/cancel tool names must be present verbatim.
      assert out =~ "task_resume"
      assert out =~ "task_stop"

      RunStore.complete(agent_id, %{status: :completed})
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Degenerate-summary retry (sampler.rs)
  # ---------------------------------------------------------------------------

  describe "degenerate_summary?/1" do
    test "flags empty, whitespace, and too-short strings" do
      assert CS.degenerate_summary?("")
      assert CS.degenerate_summary?("   \n ")
      assert CS.degenerate_summary?("Done.")
      assert CS.degenerate_summary?(nil)
      assert CS.degenerate_summary?(:not_a_string)
    end

    test "accepts a summary at or above the minimum length" do
      long = String.duplicate("a", CS.min_summary_chars())
      refute CS.degenerate_summary?(long)
    end
  end

  describe "sample_with_retry/2" do
    test "returns the first non-degenerate summary" do
      good = String.duplicate("x", CS.min_summary_chars() + 10)
      assert {:ok, ^good} = CS.sample_with_retry(fn -> {:ok, good} end)
    end

    test "retries a degenerate summary, then accepts a good one" do
      good = String.duplicate("y", CS.min_summary_chars() + 1)
      ref = :counters.new(1, [])

      sampler = fn ->
        :counters.add(ref, 1, 1)

        case :counters.get(ref, 1) do
          1 -> {:ok, "too short"}
          _ -> {:ok, good}
        end
      end

      assert {:ok, ^good} = CS.sample_with_retry(sampler, max_attempts: 2)
      assert :counters.get(ref, 1) == 2
    end

    test "gives up after max_attempts of degenerate output" do
      ref = :counters.new(1, [])

      sampler = fn ->
        :counters.add(ref, 1, 1)
        {:ok, "nope"}
      end

      assert {:error, {:degenerate_summary, "nope"}} =
               CS.sample_with_retry(sampler, max_attempts: 3)

      assert :counters.get(ref, 1) == 3
    end

    test "a sampler error short-circuits without retrying" do
      ref = :counters.new(1, [])

      sampler = fn ->
        :counters.add(ref, 1, 1)
        {:error, :boom}
      end

      assert {:error, :boom} = CS.sample_with_retry(sampler, max_attempts: 5)
      assert :counters.get(ref, 1) == 1
    end

    test "honors a custom min_chars floor" do
      short = "12345"
      assert {:ok, ^short} = CS.sample_with_retry(fn -> {:ok, short} end, min_chars: 3)
      assert {:error, {:degenerate_summary, _}} =
               CS.sample_with_retry(fn -> {:ok, short} end, min_chars: 100, max_attempts: 1)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────
  defp unique_session, do: "cs-test-" <> rand()
  defp rand, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
end
