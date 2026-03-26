defmodule OptimalSystemAgent.Receipt.BundleTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Receipt.Bundle

  describe "from_tool_call/2" do
    test "builds bundle from tool call data" do
      tool_call = %{
        id: "call_abc123",
        name: "file_read",
        arguments: %{"path" => "/tmp/test.txt"}
      }

      post_payload = %{
        session_id: "session-xyz",
        duration_ms: 42,
        result: "file contents here"
      }

      bundle = Bundle.from_tool_call(tool_call, post_payload)

      assert bundle.action_type == "tool_call"
      assert bundle.action_name == "file_read"
      assert bundle.action_id == "call_abc123"
      assert bundle.session_id == "session-xyz"
      assert bundle.duration_ms == 42
      assert bundle.result_summary == "file contents here"
      assert bundle.intent_hash != nil
      assert String.length(bundle.intent_hash) == 64
      assert bundle.attributable == true
      assert bundle.evidence == %{"path" => "/tmp/test.txt"}
    end

    test "truncates result_summary to 500 chars" do
      tool_call = %{id: "call_1", name: "shell", arguments: %{}}
      long_result = String.duplicate("x", 1000)
      post_payload = %{result: long_result, session_id: "s1", duration_ms: 10}

      bundle = Bundle.from_tool_call(tool_call, post_payload)

      assert String.length(bundle.result_summary) == 500
    end
  end

  describe "from_investigation/1" do
    test "builds bundle from investigation metadata" do
      metadata = %{
        topic: "Does coffee cause cancer?",
        claim_id: "claim-001",
        direction: "contested",
        for_score: 3.5,
        against_score: 2.1,
        grounded_for_score: 2.0,
        grounded_against_score: 1.5,
        papers_found: 12,
        source_counts: %{"semantic_scholar" => 8, "openalex" => 4},
        uncertainty: 0.45,
        belief: 0.62,
        fraudulent_citations: 1
      }

      bundle = Bundle.from_investigation(metadata)

      assert bundle.action_type == "investigation"
      assert bundle.action_name == "investigate"
      assert bundle.action_id == "claim-001"
      assert bundle.evidence.topic == "Does coffee cause cancer?"
      assert bundle.evidence.papers_found == 12
      assert bundle.evidence.fraudulent_citations == 1
      assert bundle.intent_hash != nil
    end
  end

  describe "to_audit_map/1" do
    test "converts bundle to GrpcClient-compatible map" do
      bundle = %Bundle{
        action_type: "tool_call",
        action_name: "file_read",
        agent_id: "daemon-agent",
        timestamp: ~U[2026-03-25 12:00:00Z],
        action_id: "call_abc",
        session_id: "session-1",
        intent_hash: "deadbeef" <> String.duplicate("0", 56),
        duration_ms: 100,
        result_summary: "ok",
        evidence: %{"path" => "/tmp/foo"}
      }

      audit = Bundle.to_audit_map(bundle)

      assert audit.agent_id == "daemon-agent"
      assert audit.action_id == "call_abc"
      assert audit.method == "tool_call"
      assert audit.attributable == true
      assert audit.context["action_name"] == "file_read"
      assert audit.context["session_id"] == "session-1"
      assert audit.context["duration_ms"] == "100"
      assert is_binary(audit.context["evidence_json"])
    end
  end
end
