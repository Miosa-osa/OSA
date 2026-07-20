defmodule OptimalSystemAgent.Agent.Orchestrator.CompletionSummaryTest do
  @moduledoc """
  The agents panel needs to show WHAT a worker produced, not just that it
  finished. The orchestrator rides a compact one-line `summary` on the
  `orchestrator_agent_completed` event (success + failure) so the TUI can
  render it under the finished row WITHOUT shipping the full (potentially large)
  structured result blob.

  These tests pin the extraction contract (single line, <=140 chars,
  best-effort/never-raises) and prove the summary actually rides the emitted
  completion event end-to-end.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  # Keep in lockstep with @summary_max in the orchestrator.
  @summary_max 140

  describe "completion_summary/1 — extraction contract" do
    test "derives the first meaningful line from a structured result map" do
      structured = %{summary: "Refactored the parser and added tests.", status: :completed}
      assert Orchestrator.completion_summary(structured) ==
               "Refactored the parser and added tests."
    end

    test "collapses a huge multiline result to a single trimmed line under the cap" do
      body = String.duplicate("x", 400)
      multiline = "  \n\n  First real line: #{body}\nsecond line\nthird line"

      out = Orchestrator.completion_summary(%{summary: multiline})

      # Single line: no embedded newlines survive.
      refute out =~ "\n"
      # Never longer than the cap.
      assert String.length(out) <= @summary_max
      # Took the FIRST non-blank line (leading blanks skipped), not "second line".
      assert String.starts_with?(out, "First real line:")
      refute out =~ "second line"
    end

    test "a bare string result is summarized directly" do
      assert Orchestrator.completion_summary("just a string\nmore") == "just a string"
    end

    test "a failure error string yields a short error summary" do
      err = "** (RuntimeError) boom: " <> String.duplicate("detail ", 100)
      out = Orchestrator.completion_summary(err)
      assert String.length(out) <= @summary_max
      assert String.starts_with?(out, "** (RuntimeError) boom:")
    end

    test "a result with no obvious text field falls back to a truncated inspect" do
      out = Orchestrator.completion_summary(%{code: 500, note: :no_text_here})
      assert is_binary(out)
      assert String.length(out) <= @summary_max
    end

    test "is best-effort: pathological input never raises, yields a binary" do
      # Interior whitespace-only + control chars must not blow up the emit.
      assert Orchestrator.completion_summary("\t\t   \n   \n") == ""
      assert is_binary(Orchestrator.completion_summary(nil))
      assert is_binary(Orchestrator.completion_summary({:weird, [1, 2, 3]}))
    end
  end

  describe "orchestrator_agent_completed carries the summary end-to-end" do
    setup do
      prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
      Application.put_env(:optimal_system_agent, :default_provider, :mock)
      MockProvider.reset()

      on_exit(fn ->
        if prev_provider,
          do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
          else: Application.delete_env(:optimal_system_agent, :default_provider)
      end)

      :ok
    end

    defp uniq(prefix),
      do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    test "a completed subagent emits a single-line, capped summary on the panel event" do
      parent_id = uniq("parent")
      subagent_id = uniq("agent:summ")

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent_id}")

      config = %{
        task: "say hello",
        parent_session_id: parent_id,
        agent_id: subagent_id,
        role: "tester",
        tier: :specialist,
        model: "mock-model-1.0",
        provider: :mock,
        working_dir: System.tmp_dir!(),
        timeout_ms: 10_000
      }

      assert {:ok, _} = Orchestrator.run_subagent(config)

      completed = await_completed(subagent_id, 5_000)
      assert completed.status == "completed"
      # The compact summary rides the event and is a clean single line under cap.
      assert is_binary(completed.summary)
      assert completed.summary != ""
      refute completed.summary =~ "\n"
      assert String.length(completed.summary) <= @summary_max
      # The full structured result still rides `:result`; the compact `:summary`
      # is a DISTINCT short field (never the whole blob) derived from its text.
      assert is_map(completed.result)
      assert String.length(completed.summary) <= String.length(inspect(completed.result))
    end

    # Drain the parent's session topic for THIS subagent's completion event.
    defp await_completed(subagent_id, timeout) do
      receive do
        {:osa_event, %{event: "orchestrator_agent_completed", agent_name: ^subagent_id} = ev} ->
          ev

        {:osa_event, _other} ->
          await_completed(subagent_id, timeout)
      after
        timeout -> flunk("did not receive orchestrator_agent_completed for #{subagent_id}")
      end
    end
  end
end
