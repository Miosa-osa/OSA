defmodule OptimalSystemAgent.Agent.Orchestrator.DelegationReturnsWorkTest do
  @moduledoc """
  Regression tests for the "delegated subagent results are lost" bug.

  Observed failure: the parent delegated to two explorer subagents, both ran for
  minutes and completed, and the `delegate` tool result came back as the bare
  status string `"explorer subagent completed."`. The parent concluded the
  reports "went to their own session transcripts, not to files I can read" and
  threw away the work.

  Root cause: `ResultSummarizer.summarize/2` put a content-free status header
  FIRST (so the TUI's collapsed delegate cell, which shows only the result's
  first line, showed nothing but the status), and when a child finished without
  a closing message it emitted `"(no textual output)"` and dropped every trace
  of the work the child had actually done.

  Contract asserted here: **delegation returns the work.**
    * A completed child's final text reaches the parent's tool result.
    * It is the FIRST thing in that result (nothing in front of it).
    * A silent child still yields recoverable signal, explicitly marked.
    * Oversized reports are truncated with a marker, never silently dropped.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Orchestrator.ResultSummarizer
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    :ok
  end

  defp uniq(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  # ── End-to-end: a real child Loop's final text reaches the parent ────────

  describe "end-to-end delegation" do
    test "a completed child agent's final text reaches the parent's tool result" do
      report =
        "FINDINGS: the delegate handler lives in tools/builtins/delegate/handler.ex " <>
          "and the parent-facing result is shaped by ResultSummarizer."

      Application.put_env(:optimal_system_agent, :mock_provider_final_text, report)

      parent = uniq("returns-work-parent")
      child = uniq("returns-work-child")

      result =
        Orchestrator.run_subagent(%{
          task: "explore the delegate path and report back",
          parent_session_id: parent,
          agent_id: child,
          role: "explorer",
          tier: :specialist,
          model: "mock-model-1.0",
          provider: :mock,
          working_dir: System.tmp_dir!()
        })

      assert {:ok, returned} = result

      # The work itself came back — this is the whole point of delegating.
      assert returned =~ "FINDINGS:",
             "the child's final report must reach the parent, got: #{inspect(returned)}"

      assert returned =~ "ResultSummarizer"

      # …and it LEADS. The Rust DelegateRenderer shows only the first line in a
      # collapsed tool cell, so a status header in front of the report is what
      # made the work look lost.
      assert String.starts_with?(returned, "FINDINGS:"),
             "the child's report must be the first thing in the result, got: #{inspect(returned)}"

      refute String.starts_with?(returned, "explorer subagent"),
             "a content-free status header must not precede the report"
    end
  end

  # ── Unit: the result-shaping contract ───────────────────────────────────

  describe "summarize/2" do
    test "leads with the child's final message and trails the status" do
      structured = %{
        agent_id: "agent:p:1",
        role: "explorer",
        status: :completed,
        summary: "The bug is in handler.ex line 42.",
        tool_count: 7,
        transcript_path: "/tmp/agent-p-1.md"
      }

      out = ResultSummarizer.summarize(structured, [])

      assert String.starts_with?(out, "The bug is in handler.ex line 42.")
      assert out =~ "explorer subagent completed"
      assert out =~ "7 tool call(s)"
    end

    test "falls back to the last assistant message when the structured summary is blank" do
      messages = [
        %{role: "assistant", content: "", tool_calls: [%{name: "file_grep"}]},
        %{role: "tool", content: "match in foo.ex"},
        %{role: "assistant", content: "Recovered conclusion from the transcript."}
      ]

      out =
        ResultSummarizer.summarize(
          %{role: "explorer", status: :completed, summary: ""},
          messages
        )

      assert String.starts_with?(out, "Recovered conclusion from the transcript.")
    end

    test "a silent child still returns recoverable signal, explicitly marked" do
      messages = [
        %{role: "assistant", content: "", tool_calls: [%{name: "file_grep"}]},
        %{role: "tool", content: "…"},
        %{role: "assistant", content: "   ", tool_calls: [%{name: "file_read"}]}
      ]

      out =
        ResultSummarizer.summarize(
          %{
            role: "explorer",
            status: :completed,
            summary: "",
            tool_count: 2,
            transcript_path: "/tmp/agent-silent.md"
          },
          messages
        )

      # Loudly marked so the parent never mistakes salvage for a real report.
      assert out =~ "NO FINAL REPORT"

      # …but the work is not erased: what it did, and where the record is.
      assert out =~ "file_grep"
      assert out =~ "file_read"
      assert out =~ "/tmp/agent-silent.md"

      # The old content-free phrasing that told the parent to give up is gone.
      refute out =~ "no textual output"
    end

    test "an oversized report is truncated with an explicit marker, never dropped" do
      big = String.duplicate("x", 30_000)

      out =
        ResultSummarizer.summarize(
          %{
            role: "explorer",
            status: :completed,
            summary: "HEAD OF REPORT " <> big,
            transcript_path: "/tmp/agent-big.md"
          },
          []
        )

      assert String.starts_with?(out, "HEAD OF REPORT")
      assert out =~ "truncated"
      assert out =~ "/tmp/agent-big.md"
    end
  end
end
