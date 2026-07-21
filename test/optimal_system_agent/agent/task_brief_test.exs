defmodule OptimalSystemAgent.Agent.TaskBriefTest do
  @moduledoc """
  Audit gap M1 — a durable, always-re-injected Task Brief.

  The original instruction of a long-horizon run must never be compacted away.
  These tests assert:

    * save/load round-trips atomically and the capture is IMMUTABLE (the first
      real goal is the founding brief; later goals never clobber it).
    * `Context.build/1` injects the brief into the `role: "system"` prompt when
      one exists, and injects nothing when absent (normal short chats).
    * The brief survives a compaction pass, because it lives in a `role: "system"`
      block that `Compactor` preserves verbatim.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.TaskBrief

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_brief_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      case prev_home do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      File.rm_rf(tmp)
    end)

    {:ok, session: "brief_#{System.unique_integer([:positive])}"}
  end

  describe "capture + load" do
    test "round-trips a captured brief", %{session: session} do
      assert {:ok, brief} = TaskBrief.capture(session, "Ship the durability fix")
      assert brief.goal == "Ship the durability fix"
      assert {:ok, loaded} = TaskBrief.load(session)
      assert loaded.goal == "Ship the durability fix"
      assert is_binary(loaded.created_at) and loaded.created_at != ""
    end

    test "lives next to the session's progress ledger", %{session: session} do
      brief_path = TaskBrief.path(session)
      ledger_path = ProgressLedger.path(session)
      assert Path.dirname(brief_path) == Path.dirname(ledger_path)
      assert String.ends_with?(brief_path, ".brief.json")
    end

    test "capture is immutable — a second goal never clobbers the first", %{session: session} do
      assert {:ok, _} = TaskBrief.capture(session, "Original founding goal")
      assert {:ok, again} = TaskBrief.capture(session, "A totally different later goal")
      assert again.goal == "Original founding goal"
      assert {:ok, loaded} = TaskBrief.load(session)
      assert loaded.goal == "Original founding goal"
    end

    test "empty / placeholder goals are ignored", %{session: session} do
      assert {:error, :empty_goal} = TaskBrief.capture(session, "   ")
      assert {:error, :empty_goal} = TaskBrief.capture(session, "_Not set._")
      assert {:error, :not_found} = TaskBrief.load(session)
    end

    test "load returns not_found when no brief exists", %{session: session} do
      assert {:error, :not_found} = TaskBrief.load(session)
      assert TaskBrief.context_block(session) == nil
    end

    test "custom constraints / acceptance criteria are stored and rendered", %{session: session} do
      assert {:ok, _} =
               TaskBrief.capture(session, "Build feature X",
                 constraints: "No breaking changes",
                 acceptance_criteria: "All tests green"
               )

      block = TaskBrief.context_block(session)
      assert block =~ "Build feature X"
      assert block =~ "No breaking changes"
      assert block =~ "All tests green"
    end
  end

  describe "capture chokepoint via ProgressLedger.set_goal/2" do
    test "setting the ledger goal captures the brief once", %{session: session} do
      assert {:ok, _} = ProgressLedger.set_goal(session, "Do the long-horizon task")
      assert {:ok, brief} = TaskBrief.load(session)
      assert brief.goal == "Do the long-horizon task"

      # Re-issuing the ledger goal does not replace the founding brief.
      assert {:ok, _} = ProgressLedger.set_goal(session, "Changed my mind")
      assert {:ok, brief2} = TaskBrief.load(session)
      assert brief2.goal == "Do the long-horizon task"
    end
  end

  describe "Context.build injection" do
    test "injects the brief as part of the role:system prompt when one exists", %{
      session: session
    } do
      assert {:ok, _} = TaskBrief.capture(session, "Persist the budget accumulator")

      %{messages: [system_msg | _]} = Context.build(build_state(session))

      assert system_msg.role == "system"
      text = system_content_text(system_msg)
      assert text =~ "TASK BRIEF"
      assert text =~ "Persist the budget accumulator"
    end

    test "injects nothing when no brief exists", %{session: session} do
      %{messages: [system_msg | _]} = Context.build(build_state(session))
      refute system_content_text(system_msg) =~ "TASK BRIEF"
    end
  end

  describe "survives compaction (role:system preservation)" do
    test "the brief system block is preserved verbatim through a compaction pass",
         %{session: session} do
      # Make the no-LLM micro-compaction prune deterministically regardless of
      # host thresholds: tiny protect budget + tiny minimum-savings, no protected
      # tools. Restored after the test.
      set_env(:compaction_prune_protect_tokens, 100)
      set_env(:compaction_prune_minimum_tokens, 100)
      set_env(:compaction_prune_protected_tools, [])

      assert {:ok, _} = TaskBrief.capture(session, "Keep this goal across compaction")
      brief_block = TaskBrief.context_block(session)

      brief_msg = %{role: "system", content: brief_block}

      # A conversation with big, old tool results that a real (no-LLM) compaction
      # pass will shrink — proving the pass actually did work.
      big = String.duplicate("stale tool output line\n", 400)

      convo =
        for i <- 1..8 do
          %{role: "tool", name: "some_tool", content: "result #{i}: " <> big}
        end

      messages = [brief_msg | convo]

      compacted = Compactor.micro_compact(messages)

      # The system brief message survived verbatim.
      assert Enum.any?(compacted, fn m ->
               Map.get(m, :role) == "system" and Map.get(m, :content) == brief_block
             end)

      # And the pass genuinely compacted (total size shrank).
      assert total_chars(compacted) < total_chars(messages)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp build_state(session) do
    %{
      session_id: session,
      messages: [%{role: "user", content: "please continue"}],
      working_dir: File.cwd!(),
      channel: :cli,
      provider: :ollama,
      model: nil,
      permission_tier: :full
    }
  end

  defp set_env(key, value) do
    prev = Application.get_env(:optimal_system_agent, key)
    Application.put_env(:optimal_system_agent, key, value)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, key)
        v -> Application.put_env(:optimal_system_agent, key, v)
      end
    end)
  end

  defp system_content_text(%{content: content}) when is_binary(content), do: content

  defp system_content_text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> to_string(other)
    end)
    |> Enum.join("\n")
  end

  defp total_chars(messages) do
    messages
    |> Enum.map(fn m -> m |> Map.get(:content, "") |> to_string() |> String.length() end)
    |> Enum.sum()
  end
end
